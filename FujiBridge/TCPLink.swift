import Foundation
import Network

/// TCP to the camera's command port. The phone has to already be on FUJIFILM-xxxx.
///
/// Every wait has a deadline: a Wi-Fi drop used to leave `receive` pending forever, which is the
/// spinner this app exists to replace. A timeout cancels the connection so the importer can reopen
/// from the last offset.
final class TCPLink: ByteLink, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let connectTimeout: TimeInterval
    private let readTimeout: TimeInterval
    private var connection: NWConnection?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "md.thomas.fujibridge.tcp")
    private var sink: (@Sendable (String, String) -> Void)?
    private var opened = 0.0

    private(set) var bytesIn = 0
    /// The path was held back by Local Network privacy at some point and never became ready.
    private(set) var localNetworkDenied = false
    private(set) var bytesOut = 0
    private(set) var receives = 0

    init(host: String = Fuji.cameraHost, port: UInt16 = Fuji.port, connectTimeout: TimeInterval = 8, readTimeout: TimeInterval = 10) {
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
    }

    func observe(_ sink: @escaping @Sendable (String, String) -> Void) {
        self.sink = sink
    }

    func open() async throws {
        await close()
        let endpoint = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw LinkError.rejected }
        let tcp = NWProtocolTCP.Options()
        // PTP is request/response with small commands. Nagle plus delayed ACK costs up to 200 ms per exchange.
        tcp.noDelay = true
        tcp.connectionTimeout = Int(connectTimeout.rounded(.up))
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // The camera network has no internet. Keep iOS from sending 192.168.0.1 over cellular.
        parameters.prohibitedInterfaceTypes = [.cellular]
        if host == Fuji.cameraHost {
            // A Mac on Ethernet to a home router at 192.168.0.1 would otherwise reach the router, not the camera.
            parameters.requiredInterfaceType = .wifi
            emit("Wi-Fi only", "\(host) is the camera's address. The socket may not leave over Ethernet or a VPN.")
        }
        let connection = NWConnection(host: endpoint, port: nwPort, using: parameters)
        self.connection = connection
        buffer.removeAll()
        opened = Self.clock()
        let host = host
        let port = port

        connection.viabilityUpdateHandler = { [weak self] viable in
            self?.emit("Path viability", viable ? "Viable." : "Not viable. The Wi-Fi to the body is gone or asleep.")
        }
        connection.betterPathUpdateHandler = { [weak self] better in
            if better { self?.emit("Better path", "iOS found a better path than the camera Wi-Fi.") }
        }
        connection.pathUpdateHandler = { [weak self] path in
            self?.emit("Path", Self.describe(path))
        }

        let _: Void = try await withDeadline(connectTimeout, what: "connecting to \(host):\(port)", connection: connection) { finish in
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let after = String(format: "%.0f ms after open", (Self.clock() - self.opened) * 1000)
                switch state {
                case .setup:
                    break
                case .preparing:
                    self.emit("TCP preparing", after)
                case .waiting(let error):
                    // No route, refused, or the phone is not on the camera Wi-Fi. NWConnection retries by itself.
                    if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        // Also the state while the Local Network prompt is still on screen: note it, keep waiting.
                        self.localNetworkDenied = true
                        self.emit("TCP waiting", "Local Network access denied (or not answered yet). \(after).")
                    } else {
                        self.emit("TCP waiting", "\(error.debugDescription). \(after). Is this device on FUJIFILM-xxxx?")
                    }
                case .ready:
                    self.localNetworkDenied = false
                    var local = ""
                    if let endpoint = connection.currentPath?.localEndpoint { local = " from \(endpoint)" }
                    self.emit("TCP ready", "\(after)\(local).")
                    finish(.success(()))
                case .failed(let error):
                    self.emit("TCP failed", "\(error.debugDescription). \(after).")
                    finish(.failure(error))
                case .cancelled:
                    self.emit("TCP cancelled", after)
                    finish(.failure(LinkError.closed))
                @unknown default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    func close() async {
        if let connection {
            connection.cancel()
        }
        connection = nil
        buffer.removeAll()
    }

    func write(_ data: Data) async throws {
        guard let connection else { throw LinkError.closed }
        let _: Void = try await withDeadline(readTimeout, what: "sending \(data.count) bytes", connection: connection) { finish in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(()))
                }
            })
        }
        bytesOut += data.count
    }

    func read(count: Int) async throws -> Data {
        while buffer.count < count {
            let more = try await receive(upTo: max(count - buffer.count, 64 * 1024))
            buffer.append(more)
        }
        if buffer.count == count {
            let chunk = buffer
            buffer = Data()
            return chunk
        }
        let chunk = buffer.subdata(in: buffer.startIndex..<(buffer.startIndex + count))
        buffer = buffer.subdata(in: (buffer.startIndex + count)..<buffer.endIndex)
        return chunk
    }

    private func receive(upTo maximum: Int) async throws -> Data {
        guard let connection else { throw LinkError.closed }
        let data: Data = try await withDeadline(readTimeout, what: "waiting for the body to answer", connection: connection) { finish in
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(maximum, 2 * 1024 * 1024)) { data, _, isComplete, error in
                if let error {
                    finish(.failure(error))
                } else if let data, !data.isEmpty {
                    finish(.success(data))
                } else if isComplete {
                    finish(.failure(LinkError.closed))
                } else {
                    finish(.success(Data()))
                }
            }
        }
        receives += 1
        bytesIn += data.count
        return data
    }

    /// Runs one Network.framework callback with a deadline. On timeout the connection is cancelled,
    /// because a socket that missed one answer will not get the next one right either.
    private func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        what: String,
        connection: NWConnection,
        _ body: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let once = Once()
            let finish: @Sendable (Result<T, Error>) -> Void = { result in
                if once.claim() { cont.resume(with: result) }
            }
            queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                if once.claim() {
                    self?.emit("Timeout", "No progress for \(Int(seconds)) s \(what). Cancelling the socket.")
                    connection.cancel()
                    cont.resume(throwing: LinkError.timeout(what))
                }
            }
            body(finish)
        }
    }

    private func emit(_ title: String, _ detail: String) {
        sink?(title, detail)
    }

    private static func clock() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    static func describe(_ path: NWPath) -> String {
        var parts: [String] = ["\(path.status)"]
        let interfaces = path.availableInterfaces.map { "\($0.name) \($0.type)" }
        if !interfaces.isEmpty { parts.append("via " + interfaces.joined(separator: ", ")) }
        if path.isExpensive { parts.append("expensive") }
        if path.isConstrained { parts.append("low data mode") }
        if let local = path.localEndpoint { parts.append("local \(local)") }
        if let remote = path.remoteEndpoint { parts.append("remote \(remote)") }
        if path.status != .satisfied {
            parts.append("reason \(path.unsatisfiedReason)")
        }
        return parts.joined(separator: ", ")
    }
}

/// First caller wins. Guards a continuation that a callback and a timer race to resume.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
