import Network
import XCTest
@testable import FujiBridge

/// The virtual body behind a real TCP listener on 127.0.0.1, so `TCPLink` (timeouts, buffering,
/// reconnects) runs in the tests exactly as it does against the camera. Same code on iOS and the Mac.
final class LoopbackCamera: @unchecked Sendable {
    let body: VirtualBody
    private let queue = DispatchQueue(label: "fujibridge.tests.loopback")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private(set) var accepted = 0
    /// The first N sockets are accepted and read but never answered, like a body that woke over Bluetooth
    /// and stopped listening before the phone arrived.
    var muteFirst = 0

    init(body: VirtualBody) {
        self.body = body
    }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        return try await withCheckedThrowingContinuation { cont in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { cont.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    private func serve(_ connection: NWConnection) {
        accepted += 1
        connections.append(connection)
        body.noteConnect()
        connection.start(queue: queue)
        var incoming = Data()
        var silent = accepted <= muteFirst
        func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
                guard let self, error == nil else { return }
                if let data { incoming.append(data) }
                while !silent, incoming.count >= 4 {
                    let length = Int(LE.u32(incoming, 0))
                    guard incoming.count >= length else { break }
                    let packet = incoming.subdata(in: incoming.startIndex..<(incoming.startIndex + length))
                    incoming = incoming.subdata(in: (incoming.startIndex + length)..<incoming.endIndex)
                    switch self.body.handle(packet) {
                    case .silent:
                        break
                    case .bytes(let bytes):
                        connection.send(content: bytes, completion: .idempotent)
                    case .stall(let bytes):
                        // Half-dead Wi-Fi: the data arrives, the response never does, the socket stays open.
                        connection.send(content: bytes, completion: .idempotent)
                        silent = true
                    }
                }
                if !done { pump() }
            }
        }
        pump()
    }
}

final class LoopbackTests: XCTestCase {
    private let frames = [
        CardFrame(handle: 4, name: "DSCF4436.JPG", bytes: 2_500_000, recipe: ""),
        CardFrame(handle: 9, name: "DSCF4490.JPG", bytes: 700_000, recipe: ""),
    ]

    func testLiveImportOverRealTCP() async throws {
        let faults = Faults(flakyHandshake: true, requireOk: false, stallChunk: false, lieAboutSize: true, impatientOpen: false)
        let (result, lines, dir, _) = try await importOverTCP(faults: faults)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(result.ok, result.summary)
        XCTAssertEqual(result.files.map(\.state), ["full", "full"])
        for frame in frames {
            let size = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(frame.name).path)[.size] as? Int
            XCTAssertEqual(size, frame.bytes)
        }
        XCTAssertTrue(lines.contains { $0.title == "TCP ready" })
        XCTAssertTrue(lines.contains { $0.title == "Init Fail" })
        XCTAssertTrue(lines.filter { $0.op == "partial" && $0.dir == "IN" }.allSatisfy { $0.firstByte != nil })
    }

    func testAHalfDeadSocketTimesOutAndResumes() async throws {
        let faults = Faults(flakyHandshake: false, requireOk: false, stallChunk: true, lieAboutSize: false, impatientOpen: false)
        let started = Date()
        let (result, lines, dir, camera) = try await importOverTCP(faults: faults, readTimeout: 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(result.ok, result.summary)
        XCTAssertEqual(result.files.map(\.state), ["full", "full"])
        XCTAssertTrue(lines.contains { $0.title == "Timeout" })
        XCTAssertTrue(lines.contains { $0.title == "Reconnected" })
        XCTAssertEqual(camera.accepted, 2)
        XCTAssertEqual(camera.body.partials[1].offset, Fuji.stallBytes)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        let size = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("DSCF4436.JPG").path)[.size] as? Int
        XCTAssertEqual(size, 2_500_000)
    }

    func testASilentInitGetsANewSocket() async throws {
        let body = VirtualBody(faults: .none, control: RunControl(), frames: frames)
        let camera = LoopbackCamera(body: body)
        camera.muteFirst = 1
        let port = try await camera.start()
        defer { camera.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = RunControl()
        control.ok = true
        let recorder = Recorder()
        let result = await Importer.run(
            link: TCPLink(host: "127.0.0.1", port: port, connectTimeout: 2, readTimeout: 1),
            options: RunOptions(kind: .bridge, frames: [], faults: .none, control: control, live: true, saveDirectory: dir, host: "127.0.0.1"),
            log: recorder.add
        )
        XCTAssertTrue(result.ok, result.summary)
        XCTAssertEqual(camera.accepted, 2)
        XCTAssertTrue(recorder.lines.contains { $0.title == "Reconnect" && $0.op == "reconnect" })
    }

    func testLoadMoreListsTheOlderFramesAndReportsTheCard() async throws {
        let camera = LoopbackCamera(body: VirtualBody(faults: .none, control: RunControl(), frames: frames))
        let port = try await camera.start()
        defer { camera.stop() }
        let control = RunControl()
        control.ok = true
        let listed = Box<[String]>([])
        let total = Box<Int>(0)
        let result = await Importer.run(
            link: TCPLink(host: "127.0.0.1", port: port, connectTimeout: 2, readTimeout: 2),
            options: RunOptions(kind: .bridge, frames: [], faults: .none, control: control, live: true, host: "127.0.0.1",
                                latest: 1, skipNewest: 1, cardCount: { total.value = $0 },
                                preview: { listed.value.append($0.name) }),
            log: Recorder().add
        )
        XCTAssertTrue(result.ok, result.summary)
        // Two frames on the card, the newest already shown: the next page is the older one only.
        XCTAssertEqual(total.value, 2)
        XCTAssertEqual(listed.value, ["DSCF4436.JPG"])
    }

    func testDeleteRemovesTheFramesAndNamesARefusal() async throws {
        let body = VirtualBody(faults: .none, control: RunControl(), frames: frames)
        body.protected = [9]
        let camera = LoopbackCamera(body: body)
        let port = try await camera.start()
        defer { camera.stop() }
        let control = RunControl()
        control.ok = true
        let result = await Importer.run(
            link: TCPLink(host: "127.0.0.1", port: port, connectTimeout: 2, readTimeout: 2),
            options: RunOptions(kind: .bridge, frames: [], faults: .none, control: control, live: true, host: "127.0.0.1",
                                only: [4, 9], delete: true),
            log: Recorder().add
        )
        // One deleted, the protected one refused and said so; nothing was copied.
        XCTAssertEqual(body.deleted, [4])
        XCTAssertEqual(Set(result.files.map(\.state)), ["deleted", "refused"])
        XCTAssertEqual(result.reason, "delete-refused")
        XCTAssertTrue(result.summary.contains("protected"), result.summary)
        XCTAssertTrue(body.partials.isEmpty)
    }

    func testNothingListeningFailsFastWithAReason() async throws {
        // Grab a free port, then close it, so the connect is refused.
        let camera = LoopbackCamera(body: VirtualBody(faults: .none, control: RunControl(), frames: []))
        let port = try await camera.start()
        camera.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let started = Date()
        let control = RunControl()
        let recorder = Recorder()
        let result = await Importer.run(
            link: TCPLink(host: "127.0.0.1", port: port, connectTimeout: 2, readTimeout: 2),
            options: RunOptions(kind: .bridge, frames: [], faults: .none, control: control, live: true, host: "127.0.0.1"),
            log: recorder.add
        )
        let lines = recorder.lines
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "link")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(lines.contains { $0.title == "TCP connect failed" })
    }

    func testSecondImportSkipsWhatIsAlreadyThere() async throws {
        let (first, _, dir, _) = try await importOverTCP(faults: .none)
        XCTAssertTrue(first.ok)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (second, _, _, camera) = try await importOverTCP(faults: .none, into: dir)
        XCTAssertTrue(second.ok)
        XCTAssertEqual(second.files.map(\.state), ["already", "already"])
        XCTAssertTrue(camera.body.partials.isEmpty)
    }

    private func importOverTCP(
        faults: Faults,
        readTimeout: TimeInterval = 5,
        into existing: URL? = nil
    ) async throws -> (RunResult, [TraceLine], URL, LoopbackCamera) {
        let control = RunControl()
        control.ok = true
        let camera = LoopbackCamera(body: VirtualBody(faults: faults, control: control, frames: frames))
        let port = try await camera.start()
        defer { camera.stop() }
        let dir = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let recorder = Recorder()
        let result = await Importer.run(
            link: TCPLink(host: "127.0.0.1", port: port, connectTimeout: 3, readTimeout: readTimeout),
            options: RunOptions(kind: .bridge, frames: [], faults: faults, control: control, live: true, saveDirectory: dir, host: "127.0.0.1"),
            log: recorder.add
        )
        return (result, recorder.lines, dir, camera)
    }
}

/// Lines arrive from the importer and from Network.framework's queue.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [TraceLine] = []
    var lines: [TraceLine] { lock.lock(); defer { lock.unlock() }; return store }
    func add(_ line: TraceLine) { lock.lock(); store.append(line); lock.unlock() }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
