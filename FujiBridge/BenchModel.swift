import Foundation
import Observation
import UIKit

enum BenchMode: String, CaseIterable, Identifiable {
    case virtual = "Virtual body"
    case camera = "Camera"
    var id: String { rawValue }
}

/// How many of the card's newest frames an import looks at. The rest of the card is left alone.
enum Scope: Int, CaseIterable, Identifiable {
    case latest25 = 25
    case latest100 = 100
    case all = 0
    var id: Int { rawValue }
    var label: String { self == .all ? "Whole card" : "Newest \(rawValue)" }
}

/// The photo shown full window, from either grid.
struct Viewer: Equatable {
    var tab: GalleryTab
    var id: String
}

/// What a camera run is for. All four go through the same importer.
enum Purpose: Equatable {
    /// The newest frames in scope that are not here yet.
    case newPhotos
    /// Frames picked in the preview grid.
    case selected(Set<Int>)
    /// Thumbnails and names only, nothing copied.
    case browse
    /// One frame into the cache, to look at full size.
    case open(Int)
}

@MainActor
@Observable
final class BenchModel {
    var mode: BenchMode = .virtual
    var faults = Faults()
    var phase = "Idle"
    var summary: String?
    var lines: [TraceLine] = []
    var files: [FileResult] = []
    var compare: [CompareRow] = []
    var selected: Set<Int> = Set(Catalog.roll.map(\.handle))
    var saved: [URL] = []
    var busy = false
    var waiting = false
    var progress: LiveProgress?
    var report: Report?
    var reportFiles: [URL] = []
    /// Body on USB right now ("X100VI"). When there is one, imports go over USB; otherwise over Wi-Fi.
    var usbCamera: String?
    var transport: Transport { usbCamera != nil ? .usb : .wifi }
    /// Transport of the run in progress or the last one.
    var runTransport: Transport = .wifi
    var runStarted: Date?
    var purpose: Purpose = .newPhotos
    /// The card as the last browse saw it, newest first.
    var cameraPhotos: [CardPhoto] = []
    var selection: Set<Int> = []
    /// The photo open in the viewer, if any: which grid it comes from and its id there.
    var viewer: Viewer?
    /// Frames of the card copied into the cache for a full-size look, by handle.
    var fullSize: [Int: URL] = [:]
    /// A Fujifilm body heard over Bluetooth ("X100VI-THOMAS"), when Bluetooth is on for Fuji Bridge.
    var bluetoothCamera: String?
    var bluetoothEnabled = UserDefaults.standard.bool(forKey: "BridgeBluetooth")
    /// The access point the last wake returned. On the Mac the user joins it by hand, so the UI shows it.
    var cameraWifi: CameraWifi?
    var joinByHand = false
    /// The body ignored this device: it is bonded with another one. The camera card then offers to pair.
    var bluetoothNeedsPairing = false
    /// The body is bonded with this device (the pairing went through here at least once).
    var bluetoothPairedHere = false
    /// Next wake waits for the camera's pairing screen instead of connecting to a bonded body.
    private var pairingRequested = false
    /// Why the Bluetooth step failed, so the summary does not only blame the Wi-Fi.
    private var bleFailure: String?
    /// Names already in the photos folder, to mark frames on the camera that are here.
    var importedNames: Set<String> { Set(saved.map(\.lastPathComponent)) }
    var scope: Scope = Scope(rawValue: UserDefaults.standard.object(forKey: "BridgeScope") as? Int ?? 25) ?? .latest25 {
        didSet { UserDefaults.standard.set(scope.rawValue, forKey: "BridgeScope") }
    }
    /// Camera address. 192.168.0.1 on the body's own Wi-Fi; a Mac running tools/fakecam.py for rehearsals.
    var host: String = UserDefaults.standard.string(forKey: "BridgeHost") ?? Fuji.cameraHost {
        didSet { UserDefaults.standard.set(host, forKey: "BridgeHost") }
    }

    private var control = RunControl()
    private var task: Task<Void, Never>?
    private var session: SessionLog?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var pathWatch: PathWatch?
    private var memoryObserver: NSObjectProtocol?
    /// Idle sleep would drop the Wi-Fi mid-file. The idle timer covers the phone's screen; this covers the Mac.
    private var activity: NSObjectProtocol?

    init() {
        USBCameras.shared.onChange = { [weak self] name in
            Task { @MainActor in self?.usbCamera = name }
        }
        USBCameras.shared.start()
        FujiBluetooth.shared.onCamera = { [weak self] name, advert, known in
            Task { @MainActor in
                guard let self else { return }
                self.bluetoothCamera = name
                self.bluetoothPairedHere = known
                // Bonded to another device (the phone) and never woken from here: say so before the user
                // presses Import and waits for a connection that will not come.
                if advert.kind == .reconnect && !known { self.bluetoothNeedsPairing = true }
                if advert.kind == .securePairing || advert.kind == .basicPairing || known { self.bluetoothNeedsPairing = false }
            }
        }
        if bluetoothEnabled { FujiBluetooth.shared.startScan() }
        #if DEBUG
        // Scripted rehearsals:  -BridgeAutoRun camera|usb|wifi|virtual  (-BridgeScope 5 limits the card).
        if let auto = UserDefaults.standard.string(forKey: "BridgeAutoRun") {
            Task { @MainActor in
                if auto == "usb" || auto == "browse" {
                    // The browser reports the body a moment after launch.
                    for _ in 0..<50 where self.usbCamera == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
                switch auto {
                case "virtual": self.start(.bridge, mode: .virtual)
                case "wifi": self.importFromCamera(over: .wifi)
                case "browse": self.browse()
                case "viewer":
                    self.refreshSaved()
                    if let first = self.saved.first { self.viewer = Viewer(tab: .imported, id: first.path) }
                default: self.importFromCamera(over: self.transport)
                }
            }
        }
        #endif
    }

    /// The home screen's one button: the selection when there is one, otherwise the newest in scope.
    func importFromCamera(over transport: Transport? = nil) {
        let purpose: Purpose = selection.isEmpty ? .newPhotos : .selected(selection)
        start(.bridge, mode: .camera, transport: transport ?? self.transport, purpose: purpose)
    }

    /// Fills the preview grid with the newest frames in scope. Optional: imports never need it.
    func browse() {
        start(.bridge, mode: .camera, transport: transport, purpose: .browse)
    }

    /// The frame's full-size copy in the cache, when an earlier look already fetched it whole.
    func cachedFullSize(_ photo: CardPhoto) -> URL? {
        if let known = fullSize[photo.handle] { return known }
        let cached = Self.previewFolder().appendingPathComponent(photo.name)
        let size = (try? FileManager.default.attributesOfItem(atPath: cached.path)[.size] as? NSNumber)?.intValue
        return size == photo.bytes ? cached : nil
    }

    /// Copies one frame into the cache for the viewer, unless it is there already or the camera is busy.
    func fetchFullSize(_ photo: CardPhoto) {
        if let cached = cachedFullSize(photo) {
            fullSize[photo.handle] = cached
            return
        }
        guard !busy else { return }
        start(.bridge, mode: .camera, transport: transport, purpose: .open(photo.handle))
    }

    var fetchingFullSize: Int? {
        if busy, case .open(let handle) = purpose { return handle }
        return nil
    }

    /// "Pair with the camera": wait for PAIRING REGISTRATION, bond, wake the Wi-Fi, and import.
    func pairBluetooth() {
        pairingRequested = true
        importFromCamera(over: .wifi)
    }

    /// First use asks for Bluetooth permission, then Fuji Bridge listens for the camera from then on.
    func enableBluetooth() {
        bluetoothEnabled = true
        UserDefaults.standard.set(true, forKey: "BridgeBluetooth")
        FujiBluetooth.shared.startScan()
    }

    func toggle(_ photo: CardPhoto) {
        if selection.contains(photo.handle) { selection.remove(photo.handle) } else { selection.insert(photo.handle) }
    }

    func pressOK() {
        control.ok = true
        waiting = false
        phase = "Importing"
    }

    func stop() {
        session?.event("Stop pressed", "User stopped the run.", level: "warn")
        control.aborted = true
        task?.cancel()
    }

    /// Scene phase changes. iOS suspends the app a few seconds after it leaves the screen, and the socket goes with it.
    func lifecycle(_ phase: String) {
        guard busy, let session else { return }
        // A hidden Mac window keeps running; a phone app in the background is suspended within seconds.
        let suspends = phase == "background" && !ProcessInfo.processInfo.isMacCatalystApp
        session.event("App \(phase)", suspends
            ? "Left the screen during the import. iOS will suspend the socket once background time runs out."
            : "Scene is \(phase).", level: suspends ? "warn" : "info")
    }

    func start(_ kind: ClientKind, mode: BenchMode, transport: Transport = .wifi, purpose: Purpose = .newPhotos) {
        guard !busy else { return }
        self.mode = mode
        self.purpose = purpose
        if purpose == .browse { cameraPhotos = [] }
        runTransport = mode == .camera ? transport : .wifi
        runStarted = Date()
        control = RunControl()
        control.ok = mode == .virtual && !faults.requireOk
        lines = []
        compare = []
        summary = nil
        files = []
        progress = nil
        busy = true
        waiting = mode == .virtual && faults.requireOk
        phase = waiting ? "Waiting for OK" : (mode == .camera ? (transport == .usb ? "Opening the camera" : "Connecting") : "Importing")
        var only: Set<Int>?
        switch purpose {
        case .selected(let handles): only = handles
        case .open(let handle): only = [handle]
        default: only = nil
        }
        var preview: (@Sendable (CardPhoto) -> Void)?
        if purpose == .browse {
            preview = { [weak self] photo in
                Task { @MainActor [weak self] in
                    self?.cameraPhotos.insert(photo, at: 0)
                }
            }
        }
        let faults = self.faults
        let mode = self.mode
        let handles = selected
        let host = self.host.trimmingCharacters(in: .whitespaces)
        let control = self.control
        var latest = scope == .all ? nil : scope.rawValue
        #if DEBUG
        let override = UserDefaults.standard.integer(forKey: "BridgeLatest")
        if override > 0 { latest = override }
        #endif
        // The label ends up in the report's name; the sidebar's history keeps only the "-import" ones.
        let use: String
        switch purpose {
        case .browse: use = "browse"
        case .open: use = "open"
        default: use = "import"
        }
        let session = SessionLog(label: mode == .camera ? "\(transport.rawValue)-\(use)" : "virtual-\(kind.rawValue)")
        self.session = session
        begin(session)

        let log: (TraceLine) -> Void = { [weak self] line in
            session.append(line)
            Task { @MainActor in self?.receive(line) }
        }
        let progress: @Sendable (LiveProgress) -> Void = { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }

        task = Task {
            let result: RunResult
            if mode == .virtual {
                let frames = Catalog.roll.filter { handles.contains($0.handle) }
                let body = VirtualBody(faults: faults, control: control, frames: frames)
                let link = VirtualLink(body: body)
                result = await Importer.run(
                    link: link,
                    options: RunOptions(kind: kind, frames: frames, faults: faults, control: control, paceNanos: 12_000_000, progress: progress),
                    log: log
                )
            } else {
                // Wi-Fi with a Fujifilm heard over Bluetooth: have it start its access point and join it first.
                var connectTimeout: TimeInterval = 8
                self.bleFailure = nil
                // Bluetooth on: look for the body even if it has not been heard yet (it may have just woken up).
                if transport == .wifi && self.bluetoothEnabled {
                    connectTimeout = await self.wakeAndJoin(session)
                }
                // After a Bluetooth wake the body can take its time to answer the first packet.
                let tcp = transport == .wifi ? TCPLink(host: host, connectTimeout: connectTimeout, readTimeout: connectTimeout > 8 ? 30 : 10) : nil
                let link: ByteLink = tcp ?? USBLink()
                let opening: Bool
                if case .open = purpose { opening = true } else { opening = false }
                // A rehearsal against tools/fakecam.py (loopback) must never land in the real photo library.
                let rehearsal = transport == .wifi && (host.hasPrefix("127.") || host == "localhost")
                let dir = opening ? Self.previewFolder() : (rehearsal ? Self.rehearsalFolder() : Self.folder())
                result = await Importer.run(
                    link: link,
                    options: RunOptions(
                        kind: .bridge,
                        frames: [],
                        faults: .none,
                        control: control,
                        paceNanos: 0,
                        live: true,
                        saveDirectory: dir,
                        host: host,
                        transport: transport,
                        latest: latest,
                        only: only,
                        preview: preview,
                        progress: progress
                    ),
                    log: log
                )
                FujiBluetooth.shared.release()
                if tcp == nil {
                    let usb = USBCameras.shared
                    session.event("ImageCaptureCore totals", String(format: "%d commands, %.0f ms inside ImageCaptureCore, %.0f ms in the hop back.", usb.commands, usb.iccMs, usb.hopMs), op: "net")
                    usb.resetCounters()
                }
                if let tcp {
                    session.event("Socket totals", "\(ByteFormat.string(tcp.bytesIn)) in over \(tcp.receives) receives, \(ByteFormat.string(tcp.bytesOut)) out.", op: "net")
                }
                saved = Self.photos()
                if opening, let file = result.files.first {
                    let url = dir.appendingPathComponent(file.name)
                    if FileManager.default.fileExists(atPath: url.path) { fullSize[file.handle] = url }
                }
                if case .selected = purpose {
                    selection.subtract(result.files.filter { $0.state == "full" || $0.state == "already" }.map(\.handle))
                }
            }
            files = result.files.filter { ($0.state != "skipped" && $0.state != "lost") || $0.got > 0 }
            if result.reason == "still-waiting" {
                phase = "Waiting for OK"
            } else {
                phase = result.ok ? "Copied" : "Stopped"
                waiting = false
            }
            summary = result.summary
            if !result.ok, let bleFailure { summary = "Bluetooth: \(bleFailure) Then Wi-Fi: \(result.summary)" }
            joinByHand = false
            pairingRequested = false
            if result.reason != "still-waiting" {
                busy = false
                self.progress = nil
            }
            let label = mode == .virtual ? "Virtual body" : (transport == .usb ? "Camera USB" : "Camera Wi-Fi")
            finish(session, mode: label, host: mode == .virtual ? "virtual" : (transport == .usb ? "usb" : host), result: result)
        }
    }

    func runCompare() {
        guard !busy else { return }
        busy = true
        phase = "Comparing"
        summary = nil
        let frames = Catalog.roll.filter { selected.contains($0.handle) }
        task = Task {
            let rows = await Importer.compare(frames: frames)
            compare = rows
            phase = "Idle"
            busy = false
            summary = "Five faults, run separately. Fuji Bridge keeps the offset. XApp closes the socket."
        }
    }

    func refreshSaved() {
        saved = Self.photos()
    }

    private func receive(_ line: TraceLine) {
        lines.append(line)
        guard mode == .camera, busy else { return }
        switch line.op {
        case "connect", "init", "open": phase = runTransport == .usb ? "Opening the camera" : "Connecting"
        case "net" where line.title == "Catalog ready" || line.title == "Catalog still loading": phase = "Reading the card"
        case "ok-wait": phase = "Press OK on the camera"
        case "setup", "setup-total", "thumb": phase = "Reading the card"
        case "prep", "info", "partial", "save", "file": phase = "Copying"
        case "reconnect": phase = "Reconnecting"
        default: break
        }
    }

    /// Bluetooth wake, then join. Returns how long the TCP connect may wait: the Mac needs the user to pick
    /// the network, iOS needs a few seconds to associate. Failures are traced and the import still tries.
    private func wakeAndJoin(_ session: SessionLog) async -> TimeInterval {
        let ble = FujiBluetooth.shared
        ble.sink = { [weak self] title, detail in
            session.event(title, detail, op: "ble")
            if title == "Pairing" {
                Task { @MainActor in self?.phase = "Confirm the same code on the Mac and on the camera" }
            } else if title == "Bluetooth camera" {
                Task { @MainActor in self?.phase = "Connecting to the camera" }
            }
        }
        defer { ble.sink = nil }
        phase = pairingRequested ? "Waiting for the camera's pairing screen" : "Waking the camera's Wi-Fi"
        let start = Date()
        do {
            if bluetoothCamera == nil { phase = "Looking for the camera over Bluetooth" }
            // Not heard yet: give the user a minute to switch the camera on or open its pairing screen.
            let wifi = try await ble.wakeWifi(timeout: bluetoothCamera == nil ? 60 : 20, pairing: pairingRequested)
            bluetoothNeedsPairing = false
            cameraWifi = wifi
            session.event("Wi-Fi woken", "\(wifi.ssid) in \(Int(Date().timeIntervalSince(start) * 1000)) ms over Bluetooth.", op: "ble")
            phase = "Joining \(wifi.ssid)"
            let outcome = try await WifiJoin.join(wifi)
            joinByHand = outcome == .manual
            session.event(outcome == .joined ? "Wi-Fi joined" : "Join by hand", outcome == .joined
                ? "iOS joined \(wifi.ssid)."
                : "Pick \(wifi.ssid) in the Wi-Fi menu. Fuji Bridge waits up to 2 minutes.", op: "ble")
            if outcome == .manual { phase = "Join \(wifi.ssid) in the Wi-Fi menu" }
            return outcome == .manual ? 120 : 30
        } catch {
            session.event("Bluetooth wake failed", "\(error)", op: "ble", level: "warn")
            bleFailure = "\(error)"
            if case BLEError.pairedElsewhere = error { bluetoothNeedsPairing = true }
            // Still try the Wi-Fi briefly, in case this device already joined the camera by hand.
            return 4
        }
    }

    /// Keeps the screen on and asks for background time, so a locked phone or a sleeping Mac does not kill the socket mid-file.
    private func begin(_ session: SessionLog) {
        UIApplication.shared.isIdleTimerDisabled = true
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Importing photos from the camera")
        background = UIApplication.shared.beginBackgroundTask(withName: "Fuji Bridge import") { [weak self] in
            session.event("Background time expired", "iOS is about to suspend Fuji Bridge. The socket will die.", level: "warn")
            Task { @MainActor in self?.endBackground() }
        }
        let watch = PathWatch()
        watch.start { path in
            session.event("Device path", path, op: "net")
        }
        pathWatch = watch
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            session.event("Memory warning", "iOS asked Fuji Bridge to free memory. Whole files are held in memory until saved.", level: "warn")
        }
        let env = DeviceInfo.snapshot(path: "pending")
        session.event("Session", "\(env.platform), \(env.device), \(env.system), app \(env.app) (\(env.build)), thermal \(env.thermal)\(env.lowPower ? ", Low Power Mode" : "").")
    }

    private func finish(_ session: SessionLog, mode: String, host: String, result: RunResult) {
        let environment = DeviceInfo.snapshot(path: pathWatch?.current ?? "unknown")
        pathWatch?.stop()
        pathWatch = nil
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        memoryObserver = nil
        session.close()
        let report = Diagnostics.build(log: session, mode: mode, host: host, environment: environment, result: result)
        let urls = Diagnostics.save(report)
        self.report = report
        self.reportFiles = urls + [session.jsonl]
        bridgeLog.log("Report saved: \(urls.first?.path ?? "-", privacy: .public)")
        UIApplication.shared.isIdleTimerDisabled = false
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        endBackground()
        #if DEBUG
        if UserDefaults.standard.string(forKey: "BridgeAutoRun") != nil {
            print("LATCH_REPORT \(urls.first?.path ?? "-")")
            fflush(stdout)
        }
        #endif
    }

    private func endBackground() {
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
    }

    /// Finder on the Mac, the Files app on the phone. The only place the two platforms differ, and it is a URL.
    func revealPhotos() {
        let dir = Self.folder()
        let url = ProcessInfo.processInfo.isMacCatalystApp
            ? dir
            : URL(string: "shareddocuments://" + dir.path) ?? dir
        UIApplication.shared.open(url)
    }

    /// Pictures/Fuji Bridge on the Mac, Documents/Fuji Bridge (the Files app) on the phone.
    static func folder() -> URL {
        let base: FileManager.SearchPathDirectory = ProcessInfo.processInfo.isMacCatalystApp ? .picturesDirectory : .documentDirectory
        let dir = FileManager.default.urls(for: base, in: .userDomainMask)[0]
            .appendingPathComponent("Fuji Bridge", isDirectory: true)
        // The app was called Latch: carry its Pictures/Latch over once instead of starting an empty library.
        let old = dir.deletingLastPathComponent().appendingPathComponent("Latch", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where rehearsals against the fake camera write, away from the photos.
    static func rehearsalFolder() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rehearsal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Full-size looks before importing. The system may empty it.
    static func previewFolder() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Newest first. Fuji names count up, so the name order is the shooting order.
    private static func photos() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder(), includingPropertiesForKeys: nil))?
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
    }
}
