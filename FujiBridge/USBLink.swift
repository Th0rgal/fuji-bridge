import Foundation
import ImageCaptureCore

/// What `USBLink` needs from a camera: a session, then one PTP transaction at a time.
/// `USBCameras` is the real one; the tests plug in a fake body.
protocol PTPCamera: AnyObject, Sendable {
    var sink: (@Sendable (String, String) -> Void)? { get set }
    @MainActor func openSession(timeout: TimeInterval) async throws
    @MainActor func send(_ command: Data, out: Data?) async throws -> (Data, Data)
}

/// Cameras on USB, through ImageCaptureCore. One browser for the whole app: the home screen watches it
/// to show which body is plugged in, and `USBLink` borrows its session for an import.
///
/// Same file on the Mac (Catalyst) and on an iPhone or iPad with USB-C. ImageCaptureCore calls its
/// delegates on the main thread, so every piece of state here is touched on the main actor.
final class USBCameras: NSObject, PTPCamera, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, @unchecked Sendable {
    static let shared = USBCameras()

    /// Name of the attached body ("X100VI"), nil when none. Called on the main thread.
    var onChange: ((String?) -> Void)?
    /// Events for the trace of the run in progress.
    var sink: (@Sendable (String, String) -> Void)?

    private let browser = ICDeviceBrowser()
    private(set) var camera: ICCameraDevice?
    private var open = false
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false

    var name: String? { camera?.name }

    @MainActor
    func start() {
        guard !started else { return }
        started = true
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
        browser.start()
    }

    /// Opens the PTP session if needed and waits for ImageCaptureCore to finish its own catalog pass,
    /// so our commands do not queue behind its thousands of GetObjectInfo calls.
    @MainActor
    func openSession(timeout: TimeInterval) async throws {
        guard let camera else { throw LinkError.timeout("finding a camera on USB") }
        #if !targetEnvironment(macCatalyst)
        // iPhone and iPad ask the user once before an app may send commands to a camera.
        if browser.controlAuthorizationStatus != .authorized {
            let status = await withCheckedContinuation { cont in
                browser.requestControlAuthorization { cont.resume(returning: $0) }
            }
            guard status == .authorized else { throw LinkError.rejected }
        }
        #endif
        let start = DispatchTime.now().uptimeNanoseconds
        if !open {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                camera.requestOpenSession(options: [:]) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
            open = true
            emit("USB session open", "\(camera.name ?? "camera"), \(Self.ms(since: start)).")
        }
        if !ready {
            let waited = await withTaskGroup(of: Bool.self) { group in
                group.addTask { @MainActor in
                    await withCheckedContinuation { self.readyWaiters.append($0) }
                    return true
                }
                group.addTask {
                    // Cancelled as soon as the catalog lands. Otherwise release the waiter, or the group never ends.
                    guard (try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))) != nil else { return false }
                    await MainActor.run { self.flushReady() }
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !waited { emit("Catalog so far", "\(camera.mediaFiles?.count ?? 0) files, \(camera.contents?.count ?? 0) top items.") }
            emit(waited ? "Catalog ready" : "Catalog still loading",
                 "ImageCaptureCore " + (waited ? "listed the card in \(Self.ms(since: start))." : "was still listing after \(Int(timeout)) s. Going ahead."))
        }
    }

    /// Time spent inside ImageCaptureCore, and in the hop back to us, for the trace.
    private(set) var iccMs = 0.0
    private(set) var hopMs = 0.0
    private(set) var commands = 0

    @MainActor
    func send(_ command: Data, out: Data?) async throws -> (Data, Data) {
        guard let camera, open else { throw LinkError.closed }
        let start = DispatchTime.now().uptimeNanoseconds
        var answered: UInt64 = 0
        let result: (Data, Data) = try await withCheckedThrowingContinuation { cont in
            camera.requestSendPTPCommand(command, outData: out) { data, response, error in
                answered = DispatchTime.now().uptimeNanoseconds
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: (data, response)) }
            }
        }
        let end = DispatchTime.now().uptimeNanoseconds
        iccMs += Double(answered - start) / 1_000_000
        hopMs += Double(end - answered) / 1_000_000
        commands += 1
        return result
    }

    func resetCounters() {
        iccMs = 0
        hopMs = 0
        commands = 0
    }

    private func emit(_ title: String, _ detail: String) {
        sink?(title, detail)
    }

    private func flushReady() {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private static func ms(since start: UInt64) -> String {
        String(format: "%.0f ms", Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    // MARK: ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let found = device as? ICCameraDevice, camera == nil else { return }
        camera = found
        found.delegate = self
        onChange?(found.name)
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard device == camera else { return }
        emit("USB camera removed", device.name ?? "")
        camera = nil
        open = false
        ready = false
        flushReady()
        onChange?(nil)
    }

    // MARK: ICCameraDeviceDelegate

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        open = false
        ready = false
        emit("USB session closed", error.map { "\($0)" } ?? "")
    }

    func didRemove(_ device: ICDevice) {}

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        emit("Catalog complete", "ImageCaptureCore listed \(device.mediaFiles?.count ?? 0) files.")
        ready = true
        flushReady()
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

/// A `ByteLink` over USB. The importer writes the same PTP containers it sends over TCP; this link
/// turns each command into one ImageCaptureCore transaction and hands back the data phase and the
/// response as container bytes. So the file loop, the windows, the realignment and the trace are the
/// same code on both transports.
final class USBLink: ByteLink, @unchecked Sendable {
    private let cameras: PTPCamera
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var incoming = Data()
    private var outgoing = Data()
    /// SetDevicePropValue waits here for its data phase.
    private var held: Data?
    private var pending: Task<Void, Never>?
    private var failure: Error?

    init(cameras: PTPCamera = USBCameras.shared, timeout: TimeInterval = 20) {
        self.cameras = cameras
        self.timeout = timeout
    }

    func observe(_ sink: @escaping @Sendable (String, String) -> Void) {
        cameras.sink = sink
    }

    func open() async throws {
        reset()
        // On the first connection ImageCaptureCore indexes the card (~32 s for 1771 files on an X100VI) and keeps
        // reading metadata afterwards; copying alongside it ran at 8 MB/s instead of 22. Waiting is cheaper.
        try await cameras.openSession(timeout: 60)
    }

    /// The ImageCaptureCore session stays open between runs: reopening it would make it list the card again.
    func close() async {
        reset()
    }

    func write(_ data: Data) async throws {
        lock.lock()
        incoming.append(data)
        var commands: [(Data, Data?)] = []
        while incoming.count >= 12 {
            let length = Int(LE.u32(incoming, 0))
            guard length >= 12 else {
                lock.unlock()
                throw LinkError.badLength(length)
            }
            guard incoming.count >= length else { break }
            let packet = incoming.subdata(in: incoming.startIndex..<(incoming.startIndex + length))
            incoming = incoming.subdata(in: (incoming.startIndex + length)..<incoming.endIndex)
            switch Packets.ptpType(packet) {
            case 1 where Packets.ptpCode(packet) == Fuji.setProp:
                held = packet
            case 1:
                commands.append((packet, nil))
            case 2:
                if let command = held {
                    held = nil
                    commands.append((command, Packets.payload(packet)))
                }
            default:
                break
            }
        }
        lock.unlock()
        for (command, out) in commands {
            start(command, out: out)
        }
    }

    func read(count: Int) async throws -> Data {
        while true {
            lock.lock()
            if outgoing.count >= count {
                let chunk = outgoing.subdata(in: outgoing.startIndex..<(outgoing.startIndex + count))
                outgoing = outgoing.subdata(in: (outgoing.startIndex + count)..<outgoing.endIndex)
                lock.unlock()
                return chunk
            }
            let task = pending
            let error = failure
            lock.unlock()
            if let error { throw error }
            guard let task else { throw LinkError.shortRead }
            try await wait(task)
            lock.lock()
            if pending == task { pending = nil }
            lock.unlock()
        }
    }

    private func start(_ command: Data, out: Data?) {
        let code = Packets.ptpCode(command)
        let tid = LE.u32(command, 8)
        let cameras = cameras
        let task = Task { [weak self] in
            do {
                let (data, response) = try await cameras.send(command, out: out)
                // ImageCaptureCore gives the response as a container; only its code matters here.
                let rc = response.count >= 8 ? LE.u16(response, 6) : Fuji.ok
                var bytes = Data()
                if !data.isEmpty { bytes += Packets.dataPhase(code: code, tid: tid, payload: data) }
                bytes += Packets.response(code: code, tid: tid, rc: rc)
                self?.deliver(bytes)
            } catch {
                self?.fail(error)
            }
        }
        lock.lock()
        pending = task
        lock.unlock()
    }

    private func wait(_ task: Task<Void, Never>) async throws {
        let seconds = timeout
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            Task {
                await task.value
                if once.claim() { cont.resume() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                if once.claim() {
                    self?.cameras.sink?("Timeout", "USB command got no answer for \(Int(seconds)) s.")
                    cont.resume(throwing: LinkError.timeout("waiting for the camera on USB"))
                }
            }
        }
    }

    private func deliver(_ bytes: Data) {
        lock.lock()
        outgoing.append(bytes)
        lock.unlock()
    }

    private func fail(_ error: Error) {
        lock.lock()
        failure = error
        lock.unlock()
    }

    private func reset() {
        lock.lock()
        incoming = Data()
        outgoing = Data()
        held = nil
        pending = nil
        failure = nil
        lock.unlock()
    }
}
