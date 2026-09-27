import Foundation

enum ClientKind: String, Sendable {
    case bridge
    case xapp
}

struct TraceLine: Identifiable, Equatable, Sendable, Codable {
    let id: Int
    /// Milliseconds since the run started, on the monotonic clock.
    let ms: Double
    let dir: String
    let title: String
    let detail: String
    let hex: String
    var level: String
    /// What the line belongs to, for the diagnostics report: connect, init, open, ok-wait, setup, prep, partial, save, file, reconnect, net, app, done.
    var op: String = ""
    /// How long the exchange took, when the line closes one.
    var took: Double? = nil
    var bytes: Int = 0
    var file: String = ""
    /// Partial reads only: command sent to the first byte of the data phase. The body's own latency.
    var firstByte: Double? = nil
}

struct FileResult: Equatable, Sendable, Codable {
    var handle: Int
    var name: String
    var got: Int
    var total: Int
    var state: String
}

struct RunResult: Equatable, Sendable, Codable {
    var ok: Bool
    var reason: String
    var summary: String
    var files: [FileResult]
}

struct CompareRow: Identifiable, Equatable, Sendable {
    var id: String
    var fault: String
    var xapp: String
    var bridge: String
    var xappOk: Bool
    var bridgeOk: Bool
}

/// Where the import is right now, for the live status on the home screen.
struct LiveProgress: Equatable, Sendable {
    var index: Int
    var count: Int
    var name: String
    var got: Int
    var total: Int
    var bytesPerSecond: Double
    var copiedBytes: Int
}

/// One frame as the camera describes it, for the preview grid.
struct CardPhoto: Identifiable, Equatable, Sendable {
    var handle: Int
    var name: String
    var bytes: Int
    /// PTP date string, "20260924T195324".
    var captured: String?
    /// The body's own thumbnail (160x120 JPEG on an X100VI). It carries no orientation.
    var thumb: Data
    /// EXIF orientation of the file itself, 1 when unknown. 8 is a portrait turned left.
    var orientation: Int = 1
    var id: Int { handle }
}

/// How the bytes reach the body. Only the handshake and the listing differ; the file loop is shared.
enum Transport: String, Sendable, Codable {
    /// Fuji PTP over TCP 55740: 82-byte init, OK on the camera, D621 for the list, Fuji ObjectInfo layout.
    case wifi
    /// Plain USB PTP through ImageCaptureCore: no init, no OK, GetObjectHandles, standard ObjectInfo.
    case usb
}

/// What size the body sends over Wi-Fi. The body resizes the JPEG itself, as XApp's "Resize" setting does.
/// Over USB files always come as they are on the card.
enum ImportSize: String, CaseIterable, Identifiable, Sendable {
    case original
    case small
    case extraSmall

    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: return "Original"
        case .small: return "Resized S"
        case .extraSmall: return "Resized XS"
        }
    }
    var short: String {
        switch self {
        case .original: return ""
        case .small: return "S"
        case .extraSmall: return "XS"
        }
    }
    /// D22E, or nil for the file as shot.
    var rate: UInt16? {
        switch self {
        case .original: return nil
        case .small: return 1
        case .extraSmall: return 0
        }
    }
}

struct RunOptions: Sendable {
    var kind: ClientKind
    var frames: [CardFrame]
    var faults: Faults
    var control: RunControl
    var probeOK: Bool = false
    var paceNanos: UInt64 = 0
    /// Live camera: keep polling DF00 until the body leaves WAIT, and keep every byte.
    var live: Bool = false
    var saveDirectory: URL? = nil
    /// Skip a frame already in `saveDirectory` with the same name and size.
    var skipExisting: Bool = true
    var host: String = Fuji.cameraHost
    var transport: Transport = .wifi
    /// Live runs only: copy at most the newest N frames of the card's list. Nil is the whole card.
    var latest: Int? = nil
    /// Live runs only: leave out the newest N first (they are already on screen), then apply `latest`.
    /// Browsing further back into the card is `skipNewest: shown, latest: page`.
    var skipNewest: Int = 0
    /// Live runs only: how many frames the card lists, reported once, before any scope is applied.
    var cardCount: (@Sendable (Int) -> Void)? = nil
    /// Live runs only: just these handles, whatever the scope.
    var only: Set<Int>? = nil
    /// Set to list the card instead of copying it: each frame's ObjectInfo and thumbnail come back here.
    var preview: (@Sendable (CardPhoto) -> Void)? = nil
    var progress: (@Sendable (LiveProgress) -> Void)? = nil
    /// The session's clock origin, so the importer's lines and the app's events share one timeline in the
    /// report. Without it the socket's lines restart at 0 when the import starts, after the Bluetooth wake.
    var clockOrigin: UInt64? = nil
    /// Live runs only: delete the frames in `only` from the card instead of copying them.
    var delete: Bool = false
    /// Read deadline once files are moving. XApp gives a GetObject 30 s; nil keeps the link's own.
    var transferTimeout: TimeInterval? = nil
    /// Copies only, over Wi-Fi: have the body resize each JPEG before sending it.
    var size: ImportSize = .original
}

enum Importer {
    static func run(link: ByteLink, options: RunOptions, log: @escaping (TraceLine) -> Void) async -> RunResult {
        let io = IO(link: link, log: log, origin: options.clockOrigin)
        io.transport = options.transport
        let usb = options.transport == .usb
        let wire = usb ? "USB" : "TCP \(options.host):\(Fuji.port)"
        let kind = options.kind
        let faults = options.faults
        let selected = options.frames
        var files = selected.map {
            FileResult(handle: $0.handle, name: $0.name, got: 0, total: $0.bytes, state: "lost")
        }
        guard !selected.isEmpty || options.live else {
            return RunResult(ok: false, reason: "empty", summary: "Nothing selected on the card.", files: files)
        }
        if options.control.aborted || Task.isCancelled {
            return await stop(files, io)
        }

        link.observe { title, detail in io.note(title, detail, op: "net") }
        let connectStart = io.now()
        do {
            try await link.open()
        } catch {
            io.fail(usb ? "USB open failed" : "TCP connect failed", "\(wire). \(IO.describe(error))", op: "connect", took: io.now() - connectStart)
            return RunResult(ok: false, reason: "link", summary: usb ? "No camera on USB. \(IO.describe(error))" : "Could not open TCP \(Fuji.port). \(IO.describe(error))", files: files)
        }
        io.ok(usb ? "USB connected" : "TCP connected", "\(wire).", op: "connect", took: io.now() - connectStart)

        if usb {
            // USB mode is plain PTP: ImageCaptureCore already opened the session, and the Fuji Wi-Fi
            // props (D212, D621, DF00...) answer 0x200A. Straight to the object list.
            do {
                try await usbListing(io)
            } catch {
                await link.close()
                return RunResult(ok: false, reason: "link", summary: "Could not list the card over USB. \(IO.describe(error))", files: files)
            }
        } else {
            let handshake = await wifiHandshake(io, link: link, options: options, files: files)
            if let handshake { return handshake }
        }

        var queue = selected
        if options.live {
            var handles = io.importHandles.isEmpty
                ? (io.objectCount > 0 ? Array(1...io.objectCount) : [])
                : io.importHandles
            if handles.isEmpty {
                await link.close()
                return RunResult(
                    ok: false,
                    reason: "empty",
                    summary: usb ? "The card has no objects." : "The body never listed import handles (D621) or an object count (D222).",
                    files: files
                )
            }
            options.cardCount?(handles.count)
            if let only = options.only {
                handles = handles.filter { only.contains($0) }
            } else {
                if options.skipNewest > 0 {
                    io.note("Skip newest \(options.skipNewest)", "Already listed. Continuing \(max(handles.count - options.skipNewest, 0)) frames further back.")
                    handles = Array(handles.dropLast(options.skipNewest))
                }
                if let latest = options.latest, latest > 0, handles.count > latest {
                    io.note("Newest \(latest)", "The card lists \(handles.count). Only the last \(latest) are considered.")
                    handles = Array(handles.suffix(latest))
                }
            }
            // The body lists oldest first. Newest first instead: the photos just taken are the ones wanted,
            // and a run that stops halfway has already brought them.
            queue = handles.reversed().map { handle in
                if let known = options.frames.first(where: { $0.handle == handle }) {
                    return known
                }
                return CardFrame(handle: handle, name: String(format: "DSCF%04d.JPG", handle), bytes: 0, recipe: "")
            }
            files = queue.map {
                FileResult(handle: $0.handle, name: $0.name, got: 0, total: $0.bytes, state: "lost")
            }
        }
        if options.delete {
            return await delete(queue: queue, files: files, io: io, link: link, options: options)
        }
        return await copy(queue: queue, files: files, io: io, link: link, options: options)
    }

    /// One DeleteObject per frame. A frame the body refuses (protected, card locked) is reported and skipped;
    /// a dead link ends the run, and what was deleted before stays deleted.
    private static func delete(queue: [CardFrame], files: [FileResult], io: IO, link: ByteLink, options: RunOptions) async -> RunResult {
        var files = files
        var refusals: [String] = []
        for (index, frame) in queue.enumerated() {
            if options.control.aborted || Task.isCancelled { break }
            do {
                _ = try await io.command(Fuji.deleteObject, tid: io.tid, params: [UInt32(frame.handle), 0],
                                         title: "DeleteObject \(frame.name)", op: "delete")
                io.tid += 1
                files[index].state = "deleted"
            } catch LinkError.response(let rc) {
                io.tid += 1
                files[index].state = "refused"
                refusals.append("\(frame.name): \(Self.deleteRefusal(rc))")
            } catch {
                await link.close()
                let done = files.filter { $0.state == "deleted" }.count
                return RunResult(ok: false, reason: "link", summary: "Deleted \(done) of \(queue.count), then the link failed. \(IO.describe(error))", files: files)
            }
        }
        await link.close()
        let done = files.filter { $0.state == "deleted" }.count
        if refusals.isEmpty {
            return RunResult(ok: true, reason: "deleted", summary: "Deleted \(done) from the camera.", files: files)
        }
        return RunResult(ok: done > 0, reason: "delete-refused", summary: "Deleted \(done) of \(queue.count). The camera refused " + refusals.joined(separator: "; ") + ".", files: files)
    }

    static func deleteRefusal(_ rc: UInt16) -> String {
        switch rc {
        case 0x200f: return "the photo is protected"
        case 0x200d, 0x200e: return "the card is locked or read-only"
        case 0x2005: return "this connection mode does not allow deleting"
        case 0x2009: return "the photo is no longer on the card"
        default: return String(format: "response 0x%04X", rc)
        }
    }

    /// Fuji Wi-Fi: init (retried on Init Fail), settle, OpenSession, OK on the camera, gallery props, D621.
    /// Returns a result only when the run ends here.
    private static func wifiHandshake(_ io: IO, link: ByteLink, options: RunOptions, files: [FileResult]) async -> RunResult? {
        let kind = options.kind
        let faults = options.faults
        io.note("Join the body", "Command socket is TCP \(options.host):\(Fuji.port).")
        let name = kind == .bridge ? "Fuji Bridge" : "XApp"
        let attempts = kind == .bridge ? 3 : 1
        var linked = false
        for attempt in 0..<attempts {
            if options.control.aborted || Task.isCancelled {
                return await stop(files, io)
            }
            let packet = Packets.initCommand(name: name)
            io.out(attempt == 0 ? "Init \"\(name)\"" : "Init retry \(attempt + 1)", "82 bytes, version 0x8f53e4f2 before the GUID.", packet, op: "init")
            let initStart = io.now()
            try? await link.write(packet)
            do {
                let reply = try await io.readPacket()
                let type = reply.count >= 8 ? LE.u32(reply, 4) : 0
                if type == 5 {
                    io.fail("Init Fail", kind == .bridge
                        ? "Type 5. Sending the init again."
                        : "Type 5. XApp treats this as a dead session.", op: "init", took: io.now() - initStart)
                    if kind == .xapp {
                        await link.close()
                        return RunResult(ok: false, reason: "init-fail", summary: "XApp stopped on the first Init Fail. The body often does this once; send the init again.", files: files)
                    }
                    continue
                }
                io.ok("Init Ack", "Type \(type). Session is not open yet.", op: "init", took: io.now() - initStart, bytes: reply.count)
                linked = true
                break
            } catch {
                io.fail("Init read failed", IO.describe(error), op: "init", took: io.now() - initStart)
                await link.close()
                // A body just woken over Bluetooth can accept the socket and never answer it (seen on an
                // X100VI, 27 Sept: 30 s of silence after a Local Network prompt). A fresh socket and a fresh
                // init is what XApp's retry does; the camera answers the new one or refuses it outright.
                if kind == .bridge && options.live && attempt < attempts - 1 {
                    io.note("Reconnect", "No answer to the init. Opening a new socket and sending it again.", op: "reconnect")
                    do {
                        try await link.open()
                        continue
                    } catch {
                        return RunResult(ok: false, reason: "link", summary: "Reconnect failed. \(IO.describe(error))", files: files)
                    }
                }
                return RunResult(ok: false, reason: "link", summary: "Init read failed. \(IO.describe(error))", files: files)
            }
        }
        if !linked {
            await link.close()
            return RunResult(ok: false, reason: "init-fail", summary: "Init never acknowledged.", files: files)
        }

        if kind == .bridge {
            let settleStart = io.now()
            if options.paceNanos > 0 || options.live {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            io.note("Settle 50 ms", "OpenSession inside this window gets silence, not an error code.", op: "settle", took: io.now() - settleStart)
        } else if faults.impatientOpen {
            io.fail("OpenSession with no settle", "Sent inside the 50 ms window. The socket goes quiet.")
            await link.close()
            return RunResult(ok: false, reason: "impatient", summary: "XApp sent OpenSession before the body was listening.", files: files)
        }

        let openTid: UInt32 = kind == .bridge ? 1 : 0
        do {
            _ = try await io.command(Fuji.openSession, tid: openTid, params: [1], title: "OpenSession", op: "open")
            if kind == .bridge { io.tid = 2 }
        } catch {
            await link.close()
            return RunResult(ok: false, reason: "link", summary: "OpenSession failed. \(IO.describe(error))", files: files)
        }

        if faults.requireOk || options.live {
            let limit = options.live ? 120 : (kind == .xapp ? 8 : (options.probeOK ? 3 : 240))
            var granted = !faults.requireOk && !options.live
            if options.control.ok { granted = true }
            let waitStart = io.now()
            if !granted {
                for index in 0..<limit {
                    if options.control.aborted || Task.isCancelled { return await stop(files, io) }
                    let state: UInt32
                    do {
                        state = try await io.cameraState()
                    } catch LinkError.response {
                        state = 0
                    } catch {
                        if options.live {
                            io.fail("Event poll lost the socket", IO.describe(error), op: "ok-wait", took: io.now() - waitStart)
                            await link.close()
                            return RunResult(ok: false, reason: "link", summary: "The socket died while waiting for OK. \(IO.describe(error))", files: files)
                        }
                        state = 0
                    }
                    io.wait("DF00 = \(state)", index == 0 ? "EventsList 0xD212. 0 means the rear screen is still asking for OK." : "Still locked.", op: "ok-wait")
                    if state != 0 || options.control.ok {
                        granted = true
                        break
                    }
                    if !options.probeOK {
                        try? await Task.sleep(nanoseconds: options.live ? 400_000_000 : 350_000_000)
                    }
                }
            } else if options.live {
                // OK already landed. Still read D212 once so D222 is known if D621 comes back empty.
                _ = try? await io.cameraState()
            }
            if !granted {
                if kind == .bridge && options.probeOK {
                    io.ok("Still polling for OK", "Fuji Bridge does not give up here.")
                    return RunResult(ok: true, reason: "still-waiting", summary: "Fuji Bridge is still on the event poll. It has not dropped the session.", files: files)
                }
                io.fail("Gave up waiting for OK", "Empty event lists, then the socket is closed.", op: "ok-wait-total", took: io.now() - waitStart)
                await link.close()
                return RunResult(ok: false, reason: "ok-timeout", summary: "Stopped while the body was still on the OK screen. No photo was requested.", files: files)
            }
            io.ok("OK wait over", "Rear screen released the session.", op: "ok-wait-total", took: io.now() - waitStart)
        }

        io.ok("DF00 = 2 FULL_ACCESS", options.control.ok ? "OK landed." : "Unlocked.")
        let setupStart = io.now()
        let versions: [(UInt32, String)] = [
            (Fuji.objectVersion, "DF22"),
            (Fuji.remoteObjectVersion, "DF25"),
            (Fuji.imageGetVersion, "DF21"),
            (Fuji.remoteVersion, "DF24"),
        ]
        for (prop, label) in versions {
            _ = try? await io.getProp(prop, title: "Get \(label)", op: "setup")
        }
        _ = try? await io.setProp(Fuji.clientState, value: LE.data16(20), title: "Set DF01 = 20", op: "setup")
        await gallery(io)
        io.ok("Gallery ready", "\(io.importHandles.count) handle\(io.importHandles.count == 1 ? "" : "s") in D621, D222 = \(io.objectCount).", op: "setup-total", took: io.now() - setupStart)
        return nil
    }

    /// Plain PTP: DeviceInfo for the trace, then every object on every storage.
    private static func usbListing(_ io: IO) async throws {
        let setupStart = io.now()
        if let info = try? await io.getData(Fuji.getDeviceInfo, params: [], title: "GetDeviceInfo", op: "setup") {
            io.note("Body", DeviceDescription.parse(info), op: "setup")
        }
        let list = try await io.getData(Fuji.getObjectHandles, params: [0xffff_ffff, 0, 0], title: "GetObjectHandles", op: "setup")
        io.importHandles = FujiArray.handles(list)
        io.ok("Card listed", "\(io.importHandles.count) objects, folders included.", op: "setup-total", took: io.now() - setupStart)
    }

    /// The file loop. Same code for Wi-Fi, USB and the virtual body.
    private static func copy(queue: [CardFrame], files: [FileResult], io: IO, link: ByteLink, options: RunOptions) async -> RunResult {
        var files = files
        let kind = options.kind
        let usb = options.transport == .usb
        let name = kind == .bridge ? "Fuji Bridge" : "XApp"
        var copiedBytes = 0
        var transferMs = 0.0
        // XApp sets D226 once when an import starts and back to 0 when it ends. Flipping it around every
        // file, as libfuji does, costs four commands per file and makes the body switch modes each time.
        let fujiProps = kind == .bridge && !usb
        if fujiProps {
            // XApp: D22E picks the resized size, then D226 = 1 turns resizing on (2 sends the original).
            // A resized file's length is only in ObjectInfo once D227 is on.
            if options.preview == nil, let rate = options.size.rate {
                _ = try? await io.setProp(Fuji.resizeRate, value: LE.data16(rate), title: "Set D22E = \(rate)", op: "prep")
                io.resizeRate = rate
                io.realSizeInfo = true
                _ = try? await io.setProp(Fuji.correctSize, value: LE.data16(1), title: "Set D227 = 1", op: "prep")
            }
            _ = try? await io.setProp(Fuji.compressSmall, value: LE.data16(io.forceCompression), title: "Set D226 = \(io.forceCompression)", op: "prep")
            // A deadline shorter than the body needs cuts a slow window, reconnects and asks again,
            // which is slower still.
            if let seconds = options.transferTimeout { link.setReadTimeout(seconds) }
        }
        for index in queue.indices {
            if options.control.aborted || Task.isCancelled { return await stop(files, io) }
            let frame = queue[index]
            let fileStart = io.now()
            io.file = options.live ? "#\(frame.handle)" : frame.name
            options.progress?(LiveProgress(index: index, count: queue.count, name: frame.name, got: 0, total: frame.bytes, bytesPerSecond: 0, copiedBytes: copiedBytes))
            var info: Data
            do {
                info = try await io.getData(Fuji.getObjectInfo, params: [UInt32(frame.handle)], title: options.live ? "GetObjectInfo #\(frame.handle)" : "GetObjectInfo \(frame.name)", op: "prep")
            } catch LinkError.response(let rc) {
                if options.live && rc == Fuji.invalidObject {
                    files[index].state = "skipped"
                    io.note("Skip handle \(frame.handle)", "GetObjectInfo returned 0x2009. The rest of the list is still copied.", op: "file")
                    continue
                }
                files[index].state = "lost"
                let summary = "GetObjectInfo rejected handle \(frame.handle) (0x\(String(rc, radix: 16)))."
                io.fail("ObjectInfo \(frame.name)", summary)
                await link.close()
                return RunResult(ok: false, reason: "object-info", summary: summary, files: files)
            } catch {
                await link.close()
                return RunResult(ok: false, reason: "link", summary: "GetObjectInfo failed. \(IO.describe(error))", files: files)
            }
            if let filename = ObjectInfo.filename(info) {
                let base = (filename as NSString).lastPathComponent
                if !base.isEmpty, base != ".", base != ".." {
                    files[index].name = base
                    io.file = base
                }
            }
            if usb && ObjectInfo.isFolder(info) {
                files[index].state = "skipped"
                continue
            }
            var reported = (usb ? ObjectInfo.standardSize(info) : ObjectInfo.compressedSize(info)) ?? 0
            if fujiProps, !io.realSizeInfo {
                if let size = await io.objectSize(frame.handle), size > 0 {
                    reported = size
                } else {
                    // No ObjectSize on this body: fall back to libfuji's D227 = 1, which makes ObjectInfo honest.
                    io.realSizeInfo = true
                    _ = try? await io.setProp(Fuji.correctSize, value: LE.data16(1), title: "Set D227 = 1", op: "prep")
                    if let again = try? await io.getData(Fuji.getObjectInfo, params: [UInt32(frame.handle)], title: "GetObjectInfo \(files[index].name)", op: "prep") {
                        info = again
                        reported = ObjectInfo.compressedSize(info) ?? 0
                    }
                }
            }
            let maxPartial = !usb && info.count >= 12 ? Int(LE.u32(info, 8)) : Fuji.partialMax
            io.note(
                "ObjectInfo \(files[index].name)",
                (reported == frame.bytes || frame.bytes == 0
                    ? "\(ByteFormat.string(reported)). " + (usb ? "Standard ObjectInfo, size at offset 8." : "compressed_size is the unaligned u32 at offset 13.")
                    : "Reported \(ByteFormat.string(reported)) because D227 is still 0. The file is \(ByteFormat.string(frame.bytes)).")
                    + " Body says partial max is \(ByteFormat.string(maxPartial)).",
                op: "info",
                bytes: reported,
                // Raw head of the record: the Wi-Fi layout (size at 13) differs from USB PTP (size at 8).
                data: info
            )
            if info.count < 17 || reported == 0 {
                if options.live {
                    files[index].state = "skipped"
                    io.note("Skip \(files[index].name)", "ObjectInfo had no compressed_size. Continuing with the next handle.", op: "file")
                    continue
                }
                files[index].state = "lost"
                let summary = "GetObjectInfo for \(frame.name) had no compressed_size. Refusing to guess the length from the card list."
                io.fail("ObjectInfo \(frame.name)", summary)
                await link.close()
                return RunResult(ok: false, reason: "object-info", summary: summary, files: files)
            }

            if let preview = options.preview {
                let thumb = (try? await io.getData(Fuji.getThumb, params: [UInt32(frame.handle)], title: "GetThumb \(files[index].name)", op: "thumb")) ?? Data()
                // The thumbnail is never rotated; the file's first 4 KB hold the EXIF orientation.
                let head = (try? await io.getData(Fuji.getPartial, params: [UInt32(frame.handle), 0, 4096], title: "EXIF head \(files[index].name)", op: "thumb")) ?? Data()
                preview(CardPhoto(handle: frame.handle, name: files[index].name, bytes: reported, captured: ObjectInfo.captureDate(info), thumb: thumb, orientation: Exif.orientation(head) ?? 1))
                files[index].total = reported
                files[index].state = "previewed"
                continue
            }

            if kind == .bridge, options.skipExisting, let dir = options.saveDirectory {
                let url = dir.appendingPathComponent(files[index].name)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
                // A resized copy never matches the original's size: any file by that name is enough.
                if size == reported || (io.resizeRate != nil && (size ?? 0) > 0) {
                    files[index].got = reported
                    files[index].total = reported
                    files[index].state = "already"
                    io.note("Already here", "\(files[index].name), \(ByteFormat.string(reported)). Not asked again.", op: "file", took: io.now() - fileStart)
                    continue
                }
            }

            if kind == .xapp {
                let exchange = await io.partial(handle: frame.handle, offset: 0, ask: reported, name: frame.name)
                files[index].got = exchange.bytes
                if !exchange.completed {
                    files[index].state = "lost"
                    io.fail("Socket quiet", "XApp drops the partial and closes the session. The rest of the card is never asked for.")
                    await link.close()
                    return RunResult(ok: false, reason: "stall", summary: "XApp stopped \(ByteFormat.string(exchange.bytes)) into \(frame.name) and threw the bytes away.", files: files)
                }
                if !accepted(exchange.response) {
                    files[index].state = "lost"
                    let summary = "GetPartialObject for \(frame.name) was rejected (0x\(String(exchange.response, radix: 16)))."
                    io.fail("Partial rejected", summary)
                    await link.close()
                    return RunResult(ok: false, reason: "partial", summary: summary, files: files)
                }
                files[index].state = exchange.bytes >= frame.bytes ? "full" : "partial"
                continue
            }

            options.progress?(LiveProgress(index: index, count: queue.count, name: files[index].name, got: 0, total: reported, bytesPerSecond: 0, copiedBytes: copiedBytes))
            var offset = 0
            var blob = Data()
            if options.saveDirectory != nil { blob.reserveCapacity(reported) }
            var stalls = 0
            let total = reported
            let pullStart = io.now()
            // Measured on an X100VI over USB: 1 MB from an odd offset takes ~1.5 s instead of 38 ms, and an even
            // unaligned one ~95 ms. A short window or a half-kept stall must not leave the next read there, so the
            // tail past the last 512-byte boundary is dropped and asked for again.
            func realign() {
                let extra = Importer.misalignment(offset: offset, total: total)
                guard extra > 0 else { return }
                offset -= extra
                if options.saveDirectory != nil { blob.removeLast(extra) }
                io.note("Realigned to \(offset)", "Dropped \(extra) B so the next GetPartialObject starts on a 512-byte boundary.", op: "partial")
            }
            while offset < total {
                if options.control.aborted || Task.isCancelled { return await stop(files, io) }
                let ask = min(Fuji.partialMax, total - offset)
                let exchange = await io.partial(handle: frame.handle, offset: offset, ask: ask, name: files[index].name)
                if !exchange.completed {
                    stalls += 1
                    offset += exchange.bytes
                    if options.saveDirectory != nil { blob.append(exchange.payload) }
                    realign()
                    files[index].got = offset
                    if stalls > 4 {
                        files[index].state = "lost"
                        io.fail("Socket stayed quiet", "Gave up after \(stalls) reconnects.", op: "reconnect")
                        await link.close()
                        return RunResult(
                            ok: false,
                            reason: "stall",
                            summary: "The command socket stayed quiet \(ByteFormat.string(offset)) into \(frame.name).",
                            files: files
                        )
                    }
                    io.fail("TCP stall", "\(ByteFormat.string(offset)) is in hand. Re-opening the link from that offset. \(exchange.error.map(IO.describe) ?? "")", op: "reconnect")
                    await link.close()
                    let reopenStart = io.now()
                    do {
                        try await io.reopen(settle: options.paceNanos > 0 || options.live)
                        io.ok("Reconnected", "Resuming \(files[index].name) at \(ByteFormat.string(offset)).", op: "reconnect-total", took: io.now() - reopenStart)
                    } catch {
                        io.fail("Reconnect failed", IO.describe(error), op: "reconnect-total", took: io.now() - reopenStart)
                        await link.close()
                        return RunResult(ok: false, reason: "link", summary: "Reconnect failed. \(IO.describe(error))", files: files)
                    }
                    continue
                }
                if !accepted(exchange.response) {
                    files[index].state = "lost"
                    let summary = "GetPartialObject for \(frame.name) was rejected (0x\(String(exchange.response, radix: 16)))."
                    io.fail("Partial rejected", summary)
                    await link.close()
                    return RunResult(ok: false, reason: "partial", summary: summary, files: files)
                }
                if exchange.bytes == 0 {
                    files[index].state = "lost"
                    let summary = "GetPartialObject returned no bytes for \(frame.name)."
                    io.fail("Empty partial", summary)
                    await link.close()
                    return RunResult(ok: false, reason: "partial", summary: summary, files: files)
                }
                offset += exchange.bytes
                if options.saveDirectory != nil { blob.append(exchange.payload) }
                realign()
                files[index].got = offset
                let seconds = max(0.001, (io.now() - pullStart) / 1000)
                options.progress?(LiveProgress(index: index, count: queue.count, name: files[index].name, got: offset, total: total, bytesPerSecond: Double(offset) / seconds, copiedBytes: copiedBytes + offset))
            }
            let pullMs = io.now() - pullStart
            transferMs += pullMs
            copiedBytes += offset
            // A resized file is as long as the body says, not as long as the one on the card.
            let goal = io.resizeRate == nil && frame.bytes > 0 ? frame.bytes : total
            files[index].got = offset
            files[index].total = goal
            files[index].state = goal > 0 && offset >= goal ? "full" : "partial"
            if let dir = options.saveDirectory, !blob.isEmpty {
                let url = dir.appendingPathComponent(files[index].name)
                let saveStart = io.now()
                do {
                    try blob.write(to: url, options: .atomic)
                    io.note("Saved \(files[index].name)", url.lastPathComponent, op: "save", took: io.now() - saveStart, bytes: blob.count)
                } catch {
                    io.fail("Save failed", "\(files[index].name). \(IO.describe(error))", op: "save", took: io.now() - saveStart)
                }
            }
            io.ok(
                "File \(files[index].name)",
                "\(ByteFormat.string(offset)) in \(IO.ms(pullMs)), \(ByteFormat.rate(Double(offset), ms: pullMs)). \(stalls) stall\(stalls == 1 ? "" : "s"). Whole file with props \(IO.ms(io.now() - fileStart)).",
                op: "file",
                took: io.now() - fileStart,
                bytes: offset
            )
        }
        io.file = ""

        if fujiProps {
            _ = try? await io.setProp(Fuji.compressSmall, value: LE.data16(0), title: "Set D226 = 0", op: "prep")
            if io.realSizeInfo {
                _ = try? await io.setProp(Fuji.correctSize, value: LE.data16(0), title: "Set D227 = 0", op: "prep")
            }
        }
        await link.close()
        if options.preview != nil {
            let listed = files.filter { $0.state == "previewed" }.count
            let summary = "\(listed) photo\(listed == 1 ? "" : "s") on the camera."
            io.ok("Card listed", summary, op: "done", took: io.now())
            return RunResult(ok: true, reason: "previewed", summary: summary, files: files)
        }
        let short = files.filter { $0.state == "partial" }
        if !short.isEmpty {
            let summary = "Marked \(short.count) file\(short.count == 1 ? "" : "s") done short. D227 was never set, so the body under-reported the size."
            io.fail("Import finished short", summary, op: "done", took: io.now())
            return RunResult(ok: false, reason: "truncated", summary: summary, files: files)
        }
        let copied = files.filter { $0.state == "full" }
        if usb { files.removeAll { $0.state == "skipped" && $0.got == 0 } }
        let already = files.filter { $0.state == "already" }
        if copied.isEmpty && already.isEmpty {
            let summary = "Nothing on the card could be copied."
            io.fail("Nothing copied", summary, op: "done", took: io.now())
            return RunResult(ok: false, reason: "empty", summary: summary, files: files)
        }
        var summary = "\(name) copied \(copied.count) file\(copied.count == 1 ? "" : "s") off the card."
        if !already.isEmpty {
            summary += " \(already.count) already here."
        }
        if copiedBytes > 0 && options.live {
            summary += " \(ByteFormat.string(copiedBytes)) at \(ByteFormat.rate(Double(copiedBytes), ms: transferMs))."
        }
        io.ok("Card session closed", summary, op: "done", took: io.now(), bytes: copiedBytes)
        return RunResult(ok: true, reason: "imported", summary: summary, files: files)
    }

    static func compare(frames: [CardFrame]) async -> [CompareRow] {
        let cases: [(String, String, Faults, Bool, Bool)] = [
            ("flaky", "First init fails", Faults(flakyHandshake: true, requireOk: false, stallChunk: false, lieAboutSize: false, impatientOpen: false), true, false),
            ("ok", "Body is waiting for OK", Faults(flakyHandshake: false, requireOk: true, stallChunk: false, lieAboutSize: false, impatientOpen: false), false, true),
            ("stall", "Wi-Fi dies mid-file", Faults(flakyHandshake: false, requireOk: false, stallChunk: true, lieAboutSize: false, impatientOpen: false), true, false),
            ("size", "Size field stuck at 100 KB", Faults(flakyHandshake: false, requireOk: false, stallChunk: false, lieAboutSize: true, impatientOpen: false), true, false),
            ("settle", "OpenSession before 50 ms", Faults(flakyHandshake: false, requireOk: false, stallChunk: false, lieAboutSize: false, impatientOpen: true), true, false),
        ]
        var rows: [CompareRow] = []
        for item in cases {
            let xapp = await one(.xapp, frames: frames, faults: item.2, autoOK: item.3, probe: item.4)
            let bridge = await one(.bridge, frames: frames, faults: item.2, autoOK: item.3, probe: item.4)
            rows.append(CompareRow(id: item.0, fault: item.1, xapp: xapp.summary, bridge: bridge.summary, xappOk: xapp.ok, bridgeOk: bridge.ok))
        }
        return rows
    }

    private static func one(_ kind: ClientKind, frames: [CardFrame], faults: Faults, autoOK: Bool, probe: Bool) async -> RunResult {
        let control = RunControl()
        control.ok = autoOK
        let body = VirtualBody(faults: faults, control: control, frames: frames)
        let link = VirtualLink(body: body)
        return await run(link: link, options: RunOptions(kind: kind, frames: frames, faults: faults, control: control, probeOK: probe), log: { _ in })
    }

    private static func gallery(_ io: IO) async {
        if let view = try? await io.getProp(Fuji.remotePhotoView, title: "Get DF28", op: "setup") {
            _ = try? await io.setProp(Fuji.remotePhotoView, value: view, title: "Set DF28", op: "setup")
        }
        _ = try? await io.setProp(Fuji.compressSmall, value: LE.data16(0), title: "Set D226 = 0", op: "setup")
        _ = try? await io.setProp(Fuji.correctSize, value: LE.data16(0), title: "Set D227 = 0", op: "setup")
        _ = try? await io.command(Fuji.getExtensionInfo, tid: io.tid, params: [0x1000_0001], title: "GetExtensionObjectInfo", op: "setup")
        io.tid += 1
        _ = try? await io.command(Fuji.getExtensionThumb, tid: io.tid, params: [0x1000_0001], title: "GetExtensionThumb", op: "setup")
        io.tid += 1
        _ = try? await io.command(Fuji.getFolders, tid: io.tid, params: [], title: "GetImageImportFolders", op: "setup")
        io.tid += 1
        _ = try? await io.getProp(Fuji.unknownD22B, title: "Get D22B", op: "setup")
        _ = try? await io.command(Fuji.getDates, tid: io.tid, params: [0, 30000], title: "GetImageImportDates", op: "setup")
        io.tid += 1
        _ = try? await io.getProp(Fuji.importCount, title: "Get D620", op: "setup")
        if let handles = try? await io.getProp(Fuji.importHandles, title: "Get D621 handles", op: "setup") {
            io.importHandles = FujiArray.handles(handles)
        }
    }

    /// Bytes past the last 512-byte boundary, unless the file is finished.
    static func misalignment(offset: Int, total: Int) -> Int {
        offset >= total ? 0 : offset % 512
    }

    private static func accepted(_ rc: UInt16) -> Bool {
        rc == Fuji.ok || rc == Fuji.sessionAlreadyOpen
    }

    private static func stop(_ files: [FileResult], _ io: IO) async -> RunResult {
        io.fail("Stopped", "Bytes already kept stay on the frames that finished.")
        await io.link.close()
        return RunResult(ok: false, reason: "aborted", summary: "Stopped.", files: files)
    }
}

private struct Exchange {
    var payload: Data
    var completed: Bool
    var response: UInt16
    var error: Error? = nil
    var bytes: Int { payload.count }
}

private final class IO: @unchecked Sendable {
    let link: ByteLink
    let log: (TraceLine) -> Void
    var tid: UInt32 = 1
    var objectCount = 0
    /// D227 is on: the body did not answer ObjectSize, or it is resizing.
    var realSizeInfo = false
    /// D22E while the body resizes, nil for originals.
    var resizeRate: UInt16?
    var forceCompression: UInt16 { resizeRate == nil ? 2 : 1 }
    var importHandles: [Int] = []
    var transport: Transport = .wifi
    /// Frame the next lines belong to.
    var file = ""
    private let origin: UInt64
    private let lock = NSLock()
    private var seq = 1
    /// When the length word of the last packet arrived. Partial reads use it for time to first byte.
    private var headAt = 0.0

    init(link: ByteLink, log: @escaping (TraceLine) -> Void, origin: UInt64? = nil) {
        self.link = link
        self.log = log
        self.origin = origin ?? DispatchTime.now().uptimeNanoseconds
    }

    func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - origin) / 1_000_000
    }

    func note(_ title: String, _ detail: String, op: String = "", took: Double? = nil, bytes: Int = 0, data: Data = Data()) {
        emit("...", title, detail, data, "info", op: op, took: took, bytes: bytes)
    }
    func out(_ title: String, _ detail: String, _ data: Data, op: String = "") {
        emit("OUT", title, detail, data, "info", op: op)
    }
    func ok(_ title: String, _ detail: String, op: String = "", took: Double? = nil, bytes: Int = 0) {
        emit("IN", title, detail, Data(), "ok", op: op, took: took, bytes: bytes)
    }
    func wait(_ title: String, _ detail: String, op: String = "") {
        emit("IN", title, detail, Data(), "wait", op: op)
    }
    func fail(_ title: String, _ detail: String, op: String = "", took: Double? = nil) {
        emit("ERR", title, detail, Data(), "fail", op: op, took: took)
    }

    func readPacket() async throws -> Data {
        let head = try await link.read(count: 4)
        headAt = now()
        let length = Int(LE.u32(head, 0))
        if length < 4 || length > Fuji.partialMax + 65_536 { throw LinkError.badLength(length) }
        if length == 4 { return head }
        let rest = try await link.read(count: length - 4)
        return head + rest
    }

    func finishInit(name: String) async throws -> Bool {
        let packet = Packets.initCommand(name: name)
        out("Init \"\(name)\"", "Reconnect.", packet, op: "reconnect")
        let start = now()
        try await link.write(packet)
        let reply = try await readPacket()
        let type = LE.u32(reply, 4)
        if type == 5 {
            fail("Init Fail", "Retrying the reconnect.", op: "reconnect", took: now() - start)
            try await link.write(packet)
            let again = try await readPacket()
            if LE.u32(again, 4) == 5 {
                fail("Init Fail", "The new socket rejected the init twice.", op: "reconnect", took: now() - start)
                return false
            }
            ok("Init Ack", "Command socket is back.", op: "reconnect", took: now() - start)
            return true
        }
        ok("Init Ack", "Command socket is back.", op: "reconnect", took: now() - start)
        return true
    }

    /// New command socket. OpenSession goes back to transaction id 1, then the gallery props are put back.
    func reopen(settle: Bool) async throws {
        let start = now()
        try await link.open()
        if transport == .usb {
            // ImageCaptureCore keeps its own session; there is no init or OpenSession to redo.
            ok("USB connected", "Reconnect.", op: "reconnect", took: now() - start)
            tid += 1
            return
        }
        ok("TCP connected", "Reconnect.", op: "reconnect", took: now() - start)
        let acked = try await finishInit(name: "Fuji Bridge")
        guard acked else { throw LinkError.rejected }
        let settleStart = now()
        if settle {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        note("Settle 50 ms", "OpenSession inside this window gets silence, not an error code.", op: "settle", took: now() - settleStart)
        tid = 1
        _ = try await command(Fuji.openSession, tid: 1, params: [1], title: "OpenSession", op: "reconnect")
        tid = 2
        try await setProp(Fuji.clientState, value: LE.data16(20), title: "Set DF01 = 20", op: "reconnect")
        if let rate = resizeRate {
            try await setProp(Fuji.resizeRate, value: LE.data16(rate), title: "Set D22E = \(rate)", op: "reconnect")
        }
        try await setProp(Fuji.compressSmall, value: LE.data16(forceCompression), title: "Set D226 = \(forceCompression)", op: "reconnect")
        if realSizeInfo {
            try await setProp(Fuji.correctSize, value: LE.data16(1), title: "Set D227 = 1", op: "reconnect")
        }
    }

    @discardableResult
    func command(_ code: UInt16, tid: UInt32, params: [UInt32], title: String, op: String = "cmd") async throws -> Data {
        let packet = Packets.command(code: code, tid: tid, params: params)
        out(title, Packets.hex(packet), packet, op: op)
        let start = now()
        do {
            try await link.write(packet)
            let first = try await readPacket()
            var payload = Data()
            var last = first
            if Packets.ptpType(first) == 2 {
                payload = Packets.payload(first)
                last = try await readPacket()
            }
            try accept(last)
            answered(title, last, op: op, start: start, bytes: payload.count)
            return payload
        } catch {
            fail(title, IO.describe(error), op: op, took: now() - start)
            throw error
        }
    }

    func getProp(_ prop: UInt32, title: String, op: String = "cmd") async throws -> Data {
        defer { tid += 1 }
        return try await command(Fuji.getProp, tid: tid, params: [prop], title: title, op: op)
    }

    /// Command and data phase go out in one write, so Nagle never holds the second packet for an ACK.
    func setProp(_ prop: UInt32, value: Data, title: String, op: String = "cmd") async throws {
        let packet = Packets.command(code: Fuji.setProp, tid: tid, params: [prop])
        let phase = Packets.dataPhase(code: Fuji.setProp, tid: tid, payload: value)
        out(title, Packets.hex(value), packet, op: op)
        tid += 1
        let start = now()
        do {
            try await link.write(packet + phase)
            let response = try await readPacket()
            try accept(response)
            answered(title, response, op: op, start: start, bytes: 0)
        } catch {
            fail(title, IO.describe(error), op: op, took: now() - start)
            throw error
        }
    }

    func getData(_ code: UInt16, params: [UInt32], title: String, op: String = "cmd") async throws -> Data {
        defer { tid += 1 }
        return try await command(code, tid: tid, params: params, title: title, op: op)
    }

    /// ObjectSize (0xDC04) through GetObjectPropValue, the way XApp learns how long a file is.
    func objectSize(_ handle: Int) async -> Int? {
        guard let data = try? await getData(Fuji.getObjectPropValue, params: [UInt32(handle), Fuji.objectSize], title: "ObjectSize #\(handle)", op: "info") else { return nil }
        if data.count >= 8 { return Int(LE.u32(data, 0)) | (Int(LE.u32(data, 4)) << 32) }
        if data.count >= 4 { return Int(LE.u32(data, 0)) }
        return nil
    }

    func cameraState() async throws -> UInt32 {
        let data = try await getProp(Fuji.events, title: "Get 0xD212", op: "ok-wait")
        if let count = FujiEvents.value(data, prop: Fuji.objectCount) {
            objectCount = Int(count)
        }
        return FujiEvents.value(data, prop: Fuji.cameraState) ?? 0
    }

    func partial(handle: Int, offset: Int, ask: Int, name: String) async -> Exchange {
        let packet = Packets.command(code: Fuji.getPartial, tid: tid, params: [UInt32(handle), UInt32(offset), UInt32(ask)])
        out("GetPartialObject \(name)", "Offset \(offset), max \(ask).", packet, op: "partial")
        tid += 1
        let start = now()
        var payload = Data()
        do {
            try await link.write(packet)
            let first = try await readPacket()
            // Over USB ImageCaptureCore hands over the whole window at once, so there is no first byte to time.
            let firstByte: Double? = transport == .usb ? nil : headAt - start
            if Packets.ptpType(first) == 3 {
                let rc = Packets.ptpCode(first)
                emit("IN", "Partial \(name)", "No data phase, response 0x\(String(rc, radix: 16)).", Data(), "fail", op: "partial", took: now() - start)
                return Exchange(payload: Data(), completed: true, response: rc)
            }
            payload = Packets.payload(first)
            let dataDone = now()
            let response = try await readPacket()
            let rc = Packets.ptpType(response) == 3 ? Packets.ptpCode(response) : 0
            let took = now() - start
            emit(
                "IN",
                "Partial \(name)",
                "\(ByteFormat.string(payload.count)) at \(offset) in \(IO.ms(took)), \(ByteFormat.rate(Double(payload.count), ms: took)). First byte \(firstByte.map(IO.ms) ?? "n/a"), response \(IO.ms(now() - dataDone)) after data.",
                Data(),
                Fuji.okay(rc) ? "ok" : "fail",
                op: "partial",
                took: took,
                bytes: payload.count,
                firstByte: firstByte
            )
            return Exchange(payload: payload, completed: true, response: rc)
        } catch {
            emit("ERR", "Partial \(name)", "\(IO.describe(error)). \(ByteFormat.string(payload.count)) kept from this window.", Data(), "fail", op: "partial", took: now() - start, bytes: payload.count)
            return Exchange(payload: payload, completed: false, response: 0, error: error)
        }
    }

    private func answered(_ title: String, _ response: Data, op: String, start: Double, bytes: Int) {
        let rc = Packets.ptpType(response) == 3 ? Packets.ptpCode(response) : 0
        let detail = rc == 0 ? "No response code." : String(format: "0x%04x", rc) + (bytes > 0 ? ", \(ByteFormat.string(bytes))" : "")
        emit("IN", title, detail, Data(), "ok", op: op, took: now() - start, bytes: bytes)
    }

    private func accept(_ packet: Data) throws {
        guard Packets.ptpType(packet) == 3 else { return }
        let rc = Packets.ptpCode(packet)
        if !Fuji.okay(rc) {
            throw LinkError.response(rc)
        }
    }

    private func emit(_ dir: String, _ title: String, _ detail: String, _ data: Data, _ level: String, op: String = "", took: Double? = nil, bytes: Int = 0, firstByte: Double? = nil) {
        lock.lock()
        let line = TraceLine(
            id: seq,
            ms: now(),
            dir: dir,
            title: title,
            detail: detail,
            hex: data.isEmpty ? "" : Packets.hex(data),
            level: level,
            op: op,
            took: took,
            bytes: bytes,
            file: file,
            firstByte: firstByte
        )
        seq += 1
        log(line)
        lock.unlock()
    }

    static func describe(_ error: Error) -> String {
        if let link = error as? LinkError { return link.description }
        return String(describing: error)
    }

    static func ms(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.2f s", value / 1000) : String(format: "%.0f ms", value)
    }
}

enum ByteFormat {
    static func string(_ bytes: Int) -> String {
        if bytes >= 1_048_576 {
            let mb = Double(bytes) / 1_048_576
            return String(format: mb >= 10 ? "%.0f MB" : "%.1f MB", mb)
        }
        if bytes >= 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes) B"
    }

    static func rate(_ bytes: Double, ms: Double) -> String {
        guard ms > 0 else { return "-" }
        let perSecond = bytes / (ms / 1000)
        return String(format: "%.2f MB/s", perSecond / 1_048_576)
    }
}
