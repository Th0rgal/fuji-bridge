import CoreBluetooth
import Foundation

// Fujifilm Bluetooth LE, as far as Fuji Bridge needs it: find the body, say hello, and ask it to start its
// Wi-Fi access point, then read the network name and password back.
//
// Sources: gkoh/furble (MIT) for pairing, petabyt/libfuji for the Wi-Fi wake, tiredboffin/fffw for the
// GATT tables per model and firmware. The X100VI from firmware 1.31 on is the "secure" variant: the link
// is an OS-level bond, so on an iPhone already paired with XApp the same bond serves Fuji Bridge.
//
// Photos never travel over Bluetooth: the body exposes no image service there (only a ~33 KB settings
// backup), and BLE would move a 25 MB JPEG in minutes. Bluetooth wakes the Wi-Fi; Wi-Fi carries the files.

enum FujiBLE {
    static let companyID: UInt16 = 0x04d8

    // Secure pairing (firmware from mid-2025): read STATUS, write it back with 0x20, then identify.
    static let securePairService = CBUUID(string: "123d8f06-62a1-4935-9322-833c531ee225")
    static let secureStatus = CBUUID(string: "f557d96b-8284-4667-8793-b971c1deca2a")
    // Basic pairing (older firmware): write the 4-byte token from the pairing advertisement.
    static let basicPairService = CBUUID(string: "91f1de68-dff6-466e-8b65-ff13b0f16fb8")
    static let basicToken = CBUUID(string: "aba356eb-9633-4e60-b73f-f52516dbd671")
    /// Client name shown by the body. Lives in whichever pairing service the body has.
    static let identity = CBUUID(string: "85b9163e-62d1-49ff-a6f5-054b4630d4a1")

    static let configService = CBUUID(string: "4c0020fe-f3b6-40de-acc9-77d129067b14")
    /// Indication 1. After the Wi-Fi wake: 01 = access point up, 00 = camera busy.
    static let indication1 = CBUUID(string: "a68e3f66-0fcc-4395-8d4c-aa980b5877fa")
    static let indication2 = CBUUID(string: "bd17ba04-b76b-4892-a545-b73ba1f74dae")
    static let notification1 = CBUUID(string: "f9150137-5d40-4801-a8dc-f7fc5b01da50")

    static let wifiService = CBUUID(string: "4e941240-d01d-46b9-a5ea-67636806830b")
    static let ssid = CBUUID(string: "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4")
    static let password = CBUUID(string: "e809256a-915c-4967-92e8-53b7d4cad213")

    static let shutterService = CBUUID(string: "6514eb81-4e8f-458d-aa2a-e691336cdfac")
    /// Writing 04 00 here starts the camera's access point.
    static let wifiWake = CBUUID(string: "600655e6-3637-42f1-8fb2-44efc5c63b13")

    /// Advertised by a secure body in pairing mode.
    static let securePairingAdvert = CBUUID(string: "a9d2b304-e8d6-4902-8336-352b772d7597")
    /// Advertised by a bonded body looking for its phone (seen on an X100VI, firmware 1.32).
    static let reconnectAdvert = CBUUID(string: "804daa8e-ffeb-4ab3-8e75-6edd7303208d")

    static let services: [CBUUID] = [securePairService, basicPairService, configService, wifiService, shutterService]
}

/// What a Fujifilm advertisement says about the body.
struct FujiAdvert: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// Bonded to a phone and waiting for it: connect with the existing bond.
        case reconnect
        /// Secure pairing mode: connecting starts an OS pairing prompt.
        case securePairing
        /// Older firmware in pairing mode: carries the token to write back.
        case basicPairing
        case other
    }

    var kind: Kind
    /// Short serial the secure bodies advertise ("1D7B8"), or the basic token in hex.
    var tag: String
    var token: Data?

    static func parse(manufacturer: Data?, services: [CBUUID]) -> FujiAdvert? {
        guard let data = manufacturer, data.count >= 3 else { return nil }
        let bytes = [UInt8](data)
        guard UInt16(bytes[0]) | UInt16(bytes[1]) << 8 == FujiBLE.companyID else { return nil }
        let type = bytes[2]
        let rest = Array(bytes.dropFirst(3))
        if type == 0x02, rest.count >= 4 {
            let token = Data(rest.prefix(4))
            return FujiAdvert(kind: .basicPairing, tag: token.map { String(format: "%02x", $0) }.joined(), token: token)
        }
        let text = String(decoding: rest.filter { $0 >= 0x20 && $0 < 0x7f }, as: UTF8.self)
        if services.contains(FujiBLE.securePairingAdvert) { return FujiAdvert(kind: .securePairing, tag: text, token: nil) }
        // Both seen from an X100VI (firmware 1.32) bonded to an iPhone: 804daa8e first, then the secure pairing
        // service 123d8f06 once the phone's Bluetooth went off. Either way it only accepts its bonded device.
        if services.contains(FujiBLE.reconnectAdvert) || services.contains(FujiBLE.securePairService) {
            return FujiAdvert(kind: .reconnect, tag: text, token: nil)
        }
        return FujiAdvert(kind: .other, tag: text, token: nil)
    }
}

/// The body's access point, as read over Bluetooth.
struct CameraWifi: Equatable, Sendable {
    var ssid: String
    var password: String
}

enum BLEError: Error, CustomStringConvertible {
    case off
    case unauthorized
    case notFound
    case missing(CBUUID)
    case timeout(String)
    case busy
    case disconnected(String)
    /// The body advertises for the device it is bonded with and ignores this one.
    case pairedElsewhere(String)

    var description: String {
        switch self {
        case .off: return "Bluetooth is off"
        case .unauthorized: return "Fuji Bridge is not allowed to use Bluetooth (Settings › Privacy › Bluetooth)"
        case .notFound: return "No Fujifilm camera advertising nearby. Is the camera on?"
        case .missing(let uuid): return "The camera has no characteristic \(uuid.uuidString)"
        case .timeout(let what): return "Timed out \(what)"
        case .busy: return "The camera said it is busy and did not start its Wi-Fi"
        case .disconnected(let why): return "Bluetooth link dropped: \(why)"
        case .pairedElsewhere(let name): return "\(name) is paired with another device and did not accept this one. Pair it with this device first."
        }
    }
}

/// The GATT operations the handshake needs. CoreBluetooth provides them for real; tests plug in a fake body.
protocol GATTClient: AnyObject {
    func has(_ characteristic: CBUUID) async -> Bool
    func read(_ characteristic: CBUUID) async throws -> Data
    func write(_ characteristic: CBUUID, _ value: Data) async throws
    /// Best effort: some bodies lack some notifications.
    func subscribe(_ characteristic: CBUUID) async
    /// Next value the body pushes on this characteristic, or nil after the timeout.
    func nextValue(_ characteristic: CBUUID, timeout: TimeInterval) async -> Data?
}

/// The Wi-Fi wake, independent of CoreBluetooth so it can be tested.
enum FujiWake {
    static let clientName = "Fuji Bridge"

    /// Identify (secure or basic), subscribe, read the SSID, write 04 00, read the password, wait for 01.
    static func run(_ gatt: GATTClient, token: Data?, log: (String, String) -> Void) async throws -> CameraWifi {
        if await gatt.has(FujiBLE.secureStatus) {
            let status = try await readThroughPairing(gatt, FujiBLE.secureStatus, log: log)
            log("Secure status", hex(status))
            guard status.count == 4 else { throw BLEError.missing(FujiBLE.secureStatus) }
            try await gatt.write(FujiBLE.secureStatus, ack(status))
        } else if let token {
            try await gatt.write(FujiBLE.basicToken, token)
            log("Token sent", hex(token))
        }
        try await gatt.write(FujiBLE.identity, Data(clientName.utf8))
        log("Identified", clientName)

        for characteristic in [FujiBLE.indication1, FujiBLE.indication2, FujiBLE.notification1, FujiBLE.ssid] {
            await gatt.subscribe(characteristic)
        }

        let ssid = text(try await gatt.read(FujiBLE.ssid))
        log("SSID", ssid)
        // Drop any indication from before the wake: only the answer to 04 00 counts.
        _ = await gatt.nextValue(FujiBLE.indication1, timeout: 0)
        try await gatt.write(FujiBLE.wifiWake, Data([0x04, 0x00]))
        log("Wi-Fi wake sent", "04 00")
        let password = (try? await gatt.read(FujiBLE.password)).map(text) ?? ""
        log("Password", password.isEmpty ? "none" : "\(password.count) characters")

        // The body answers on indication 1 a few seconds later: 01 is up, 00 is busy.
        if let answer = await gatt.nextValue(FujiBLE.indication1, timeout: 12) {
            log("Wi-Fi answer", hex(answer))
            if answer.first == 0x00 { throw BLEError.busy }
        } else {
            log("Wi-Fi answer", "none within 12 s, trying anyway")
        }
        guard !ssid.isEmpty else { throw BLEError.missing(FujiBLE.ssid) }
        return CameraWifi(ssid: ssid, password: password)
    }

    /// The first encrypted read starts OS pairing, and macOS fails it at once with "Encryption is insufficient"
    /// instead of waiting while the user compares the six-digit code. Dropping the link then makes the camera
    /// show "pairing is canceled" (seen on an X100VI). So keep the link and ask again until the bond is there.
    static func readThroughPairing(_ gatt: GATTClient, _ characteristic: CBUUID, attempts: Int = 30, pause: UInt64 = 2_000_000_000, log: (String, String) -> Void) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await gatt.read(characteristic)
            } catch where isPairingPending(error) && attempt < attempts {
                attempt += 1
                if attempt == 1 {
                    log("Pairing", "Confirm the same six-digit code on this device and on the camera.")
                }
                try await Task.sleep(nanoseconds: pause)
            }
        }
    }

    /// ATT "insufficient authentication" (5) or "insufficient encryption" (15): the bond is not there yet.
    static func isPairingPending(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == CBATTErrorDomain && (error.code == CBATTError.insufficientEncryption.rawValue
            || error.code == CBATTError.insufficientAuthentication.rawValue)
    }

    /// STATUS comes back with its last byte set to 0x20.
    static func ack(_ status: Data) -> Data {
        var bytes = [UInt8](status)
        if bytes.count == 4 { bytes[3] = 0x20 }
        return Data(bytes)
    }

    /// Fixed-size string fields, NUL padded.
    static func text(_ data: Data) -> String {
        String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

/// CoreBluetooth central for Fujifilm bodies. Scans while asked to, remembers the last body it used,
/// and runs `FujiWake` over a real connection. Same file on the iPhone and on the Mac (Catalyst).
final class FujiBluetooth: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, GATTClient, @unchecked Sendable {
    static let shared = FujiBluetooth()

    /// Called on the main thread when a Fujifilm body shows up, or its name or advertisement changes.
    /// The flag says whether this device has woken that body before (so it is bonded here).
    var onCamera: ((String, FujiAdvert, Bool) -> Void)?
    private var names: [UUID: String] = [:]
    /// When each body was last heard. Switching to pairing mode gives the body a new address, and the old
    /// identifier never answers again, so only recently heard ones are worth connecting to.
    private var lastSeen: [UUID: Date] = [:]
    /// Trace sink for the run in progress.
    var sink: (@Sendable (String, String) -> Void)?

    private let queue = DispatchQueue(label: "md.thomas.fujibridge.ble")
    private lazy var central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    private let lock = NSLock()
    private var found: [UUID: (CBPeripheral, FujiAdvert)] = [:]
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var stateWaiters: [CheckedContinuation<CBManagerState, Never>] = []
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var discoverWaiter: CheckedContinuation<Void, Error>?
    private var pendingServices = 0
    private var readWaiters: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writeWaiters: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var valueWaiters: [CBUUID: CheckedContinuation<Data?, Never>] = [:]
    /// Notifications that arrived with nobody waiting; `nextValue` hands them out first.
    private var buffered: [CBUUID: Data] = [:]
    private var pendingReads: Set<CBUUID> = []

    private static let rememberKey = "BridgeBluetoothCamera"

    // MARK: Scanning

    /// True between asking for a connection and letting it go; the watchdog leaves the radio alone then.
    private var busy = false
    private var watchdog = false

    /// Starts listening for Fujifilm advertisements, and keeps listening: a watchdog restarts the scan
    /// whenever a connection attempt or the system stopped it. The first call asks for Bluetooth permission.
    func startScan() {
        queue.async {
            if self.central.state == .poweredOn { self.scan() }
            if !self.watchdog {
                self.watchdog = true
                self.guardScan()
            }
        }
    }

    private func guardScan() {
        if central.state == .poweredOn && !busy && !central.isScanning {
            emit("Scan restarted", "The scan had stopped; listening again.")
            scan()
        }
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.guardScan() }
    }

    func stopScan() {
        queue.async { if self.central.state == .poweredOn { self.central.stopScan() } }
    }

    /// Every Fujifilm advert seen so far carries one of these: bonded (804daa8e, 123d8f06), pairing
    /// (a9d2b304), older bodies (af854c2e, 117c4142). Scanning for them, rather than for everything, keeps
    /// working when Fuji Bridge is not the frontmost app, which is exactly when the user is at the camera.
    private static let advertised: [CBUUID] = [
        FujiBLE.reconnectAdvert, FujiBLE.securePairService, FujiBLE.securePairingAdvert,
        CBUUID(string: "af854c2e-b214-458e-97e2-912c4ecf2cb8"), CBUUID(string: "117c4142-edd4-4c77-8696-dd18eebb770a"),
    ]

    private func scan() {
        // Duplicates on: lastSeen stays fresh, and an advert change (pairing mode) is seen at once.
        central.scanForPeripherals(withServices: Self.advertised, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        checkConnected()
    }

    /// A body connected to this device (XApp holds one on the phone) stops advertising, so scanning never
    /// hears it. Ask the system for it instead, now and every few seconds while Fuji Bridge listens.
    private func checkConnected() {
        for peripheral in central.retrieveConnectedPeripherals(withServices: [FujiBLE.configService, FujiBLE.shutterService]) {
            let advert = FujiAdvert(kind: .reconnect, tag: "connected", token: nil)
            let isNew: Bool = lock.withLock {
                let known = found[peripheral.identifier] != nil
                found[peripheral.identifier] = (peripheral, advert)
                lastSeen[peripheral.identifier] = Date()
                return !known
            }
            if isNew {
                let name = peripheral.name ?? "Fujifilm"
                // Connected to this device means bonded here.
                DispatchQueue.main.async { self.onCamera?(name, advert, true) }
            }
        }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.central.isScanning else { return }
            self.checkConnected()
        }
    }

    func isRemembered(_ id: UUID) -> Bool {
        UserDefaults.standard.string(forKey: Self.rememberKey) == id.uuidString
    }

    private static let tagKey = "BridgeBluetoothTag"

    /// Bonded with this device. The body changes address between modes, so the identifier alone is not
    /// enough; the short serial in its adverts ("1D7B8") stays the same.
    func isKnown(_ id: UUID, tag: String) -> Bool {
        if isRemembered(id) { return true }
        guard !tag.isEmpty, tag != "connected" else { return false }
        return UserDefaults.standard.string(forKey: Self.tagKey) == tag
    }

    /// An encrypted read went through: the OS bond with this body exists, whatever happens next.
    private func markPaired(_ target: CBPeripheral, advert: FujiAdvert) {
        UserDefaults.standard.set(target.identifier.uuidString, forKey: Self.rememberKey)
        if !advert.tag.isEmpty && advert.tag != "connected" {
            UserDefaults.standard.set(advert.tag, forKey: Self.tagKey)
        }
        let name = target.name ?? "Fujifilm"
        let bonded = FujiAdvert(kind: .reconnect, tag: advert.tag, token: nil)
        DispatchQueue.main.async { self.onCamera?(name, bonded, true) }
        emit("Paired", "\(name) is bonded with this device.")
    }

    // MARK: Wake

    /// Connects to the nearest (or remembered) Fujifilm body and asks it to start its Wi-Fi.
    /// With `pairing`, waits for a body in pairing mode (PAIRING REGISTRATION on the camera) and bonds with it.
    func wakeWifi(timeout: TimeInterval = 20, pairing: Bool = false) async throws -> CameraWifi {
        let state = await poweredState()
        switch state {
        case .poweredOn: break
        case .unauthorized: throw BLEError.unauthorized
        default: throw BLEError.off
        }
        // An X100VI drops the link the moment the pairing code is confirmed (seen at 18:52:17, the same
        // millisecond as the "insufficient encryption" answer), then waits for the bonded device to come back.
        // So a drop during or right after pairing means: reconnect and run the handshake again, now encrypted.
        var pairingSeen = false
        var lastError: Error = BLEError.notFound
        for attempt in 1...3 {
            let (target, advert) = try await pick(timeout: attempt == 1 ? (pairing ? 120 : timeout) : 30, pairing: pairing && attempt == 1)
            emit("Bluetooth camera", "\(target.name ?? "Fujifilm") \(advert.kind.rawValue) \(advert.tag), attempt \(attempt)")
            let remembered = isKnown(target.identifier, tag: advert.tag)
            do {
                try await connect(target, timeout: 15)
            } catch BLEError.timeout {
                // A bonded body advertises for its own phone and never answers anyone else. Seen from a Mac
                // next to an X100VI paired with XApp on an iPhone.
                if advert.kind == .reconnect && !remembered && !pairingSeen { throw BLEError.pairedElsewhere(target.name ?? "The camera") }
                lastError = BLEError.timeout("connecting over Bluetooth")
                if pairingSeen { continue }
                throw lastError
            }
            do {
                try await discover(timeout: 15)
                let wifi = try await FujiWake.run(self, token: advert.token) { title, detail in
                    if title == "Pairing" { pairingSeen = true }
                    if title == "Secure status" { markPaired(target, advert: advert) }
                    emit(title, detail)
                }
                // Keep the link: XApp stays connected while it joins the camera's Wi-Fi, and a body that loses
                // its app on both radios gives up with "NOT FOUND" (seen on the X100VI, 77 s after the wake).
                // `release()` drops it once the Wi-Fi session is up or the run ends.
                UserDefaults.standard.set(target.identifier.uuidString, forKey: Self.rememberKey)
                emit("Bluetooth kept", "Link stays open until the Wi-Fi session answers.")
                return wifi
            } catch {
                disconnect()
                lastError = error
                let dropped: Bool
                if case BLEError.disconnected = error { dropped = true } else { dropped = false }
                guard pairingSeen || dropped || FujiWake.isPairingPending(error), attempt < 3 else { throw error }
                emit("Reconnecting", "Link lost after pairing (\(error)). Connecting again, attempt \(attempt + 1) of 3.")
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw lastError
    }

    private func poweredState() async -> CBManagerState {
        let current: CBManagerState = queue.sync { central.state }
        if current != .unknown && current != .resetting { return current }
        return await withCheckedContinuation { cont in
            queue.async {
                if self.central.state != .unknown && self.central.state != .resetting {
                    cont.resume(returning: self.central.state)
                } else {
                    self.stateWaiters.append(cont)
                }
            }
        }
    }

    /// A body already connected to this device (XApp keeps one), else the remembered one, else the
    /// strongest advertising Fujifilm.
    private func pick(timeout: TimeInterval, pairing: Bool) async throws -> (CBPeripheral, FujiAdvert) {
        let remembered = UserDefaults.standard.string(forKey: Self.rememberKey).flatMap(UUID.init(uuidString:))
        startScan()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // A body connected to this device (XApp on the phone, or macOS itself right after pairing) does
            // not advertise. Ask the system every round, not just once.
            if !pairing {
                let connected = queue.sync {
                    central.retrieveConnectedPeripherals(withServices: [FujiBLE.configService, FujiBLE.shutterService, FujiBLE.securePairService])
                }
                if let already = connected.first {
                    emit("Bluetooth", "\(already.name ?? "camera") is already connected to this device. Sharing the link.")
                    return (already, FujiAdvert(kind: .reconnect, tag: "connected", token: nil))
                }
            }
            var candidates: [(CBPeripheral, FujiAdvert)] = lock.withLock {
                let fresh = Date().addingTimeInterval(-20)
                return found.values
                    .filter { (lastSeen[$0.0.identifier] ?? .distantPast) > fresh }
                    .sorted { (lastSeen[$0.0.identifier] ?? .distantPast) > (lastSeen[$1.0.identifier] ?? .distantPast) }
            }
            if pairing {
                // An X100VI (firmware 1.32) in PAIRING REGISTRATION keeps advertising 123d8f06 like a bonded
                // body; a9d2b304 only shows up once connected. So prefer a pairing advert, but take any Fujifilm.
                let pairingAdverts = candidates.filter { $0.1.kind == .securePairing || $0.1.kind == .basicPairing }
                if !pairingAdverts.isEmpty { candidates = pairingAdverts }
            }
            if let known = candidates.first(where: { $0.0.identifier == remembered }) { return known }
            if let any = candidates.first { return any }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw BLEError.notFound
    }

    private func connect(_ target: CBPeripheral, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.busy = true
                self.central.stopScan()
                self.peripheral = target
                target.delegate = self
                self.connectWaiter = cont
                self.central.connect(target, options: nil)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard let waiter = self.connectWaiter else { return }
                    self.connectWaiter = nil
                    self.busy = false
                    self.central.cancelPeripheralConnection(target)
                    waiter.resume(throwing: BLEError.timeout("connecting over Bluetooth"))
                }
            }
        }
        emit("Bluetooth connected", target.name ?? "")
    }

    private func discover(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.characteristics = [:]
                self.discoverWaiter = cont
                self.peripheral?.discoverServices(FujiBLE.services)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard let waiter = self.discoverWaiter else { return }
                    self.discoverWaiter = nil
                    waiter.resume(throwing: BLEError.timeout("discovering Bluetooth services"))
                }
            }
        }
        let count = queue.sync { characteristics.count }
        emit("Bluetooth services", "\(count) characteristics")
    }

    /// Ends the link a successful wake left open.
    func release() {
        disconnect()
    }

    private func disconnect() {
        queue.async {
            if let peripheral = self.peripheral { self.central.cancelPeripheralConnection(peripheral) }
            self.peripheral = nil
            self.busy = false
        }
    }

    // MARK: GATTClient

    func has(_ characteristic: CBUUID) async -> Bool {
        queue.sync { characteristics[characteristic] != nil }
    }

    func read(_ characteristic: CBUUID) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            queue.async {
                guard let peripheral = self.peripheral, let chr = self.characteristics[characteristic] else {
                    cont.resume(throwing: BLEError.missing(characteristic))
                    return
                }
                // A read on a dropped link never answers; fail now so the caller can reconnect.
                guard peripheral.state == .connected else {
                    cont.resume(throwing: BLEError.disconnected("link already closed"))
                    return
                }
                self.readWaiters[characteristic] = cont
                self.pendingReads.insert(characteristic)
                peripheral.readValue(for: chr)
                // A secure read can sit behind the OS pairing prompt; give the user time to answer it.
                self.queue.asyncAfter(deadline: .now() + 30) {
                    guard let waiter = self.readWaiters.removeValue(forKey: characteristic) else { return }
                    self.pendingReads.remove(characteristic)
                    waiter.resume(throwing: BLEError.timeout("reading \(characteristic.uuidString)"))
                }
            }
        }
    }

    func write(_ characteristic: CBUUID, _ value: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let peripheral = self.peripheral, let chr = self.characteristics[characteristic] else {
                    cont.resume(throwing: BLEError.missing(characteristic))
                    return
                }
                self.writeWaiters[characteristic] = cont
                peripheral.writeValue(value, for: chr, type: .withResponse)
                self.queue.asyncAfter(deadline: .now() + 10) {
                    guard let waiter = self.writeWaiters.removeValue(forKey: characteristic) else { return }
                    waiter.resume(throwing: BLEError.timeout("writing \(characteristic.uuidString)"))
                }
            }
        }
    }

    func subscribe(_ characteristic: CBUUID) async {
        queue.async {
            guard let peripheral = self.peripheral, let chr = self.characteristics[characteristic],
                  chr.properties.contains(.notify) || chr.properties.contains(.indicate) else { return }
            peripheral.setNotifyValue(true, for: chr)
        }
    }

    func nextValue(_ characteristic: CBUUID, timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            queue.async {
                if let value = self.buffered.removeValue(forKey: characteristic) {
                    cont.resume(returning: value)
                    return
                }
                if timeout <= 0 {
                    cont.resume(returning: nil)
                    return
                }
                self.valueWaiters[characteristic] = cont
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if let waiter = self.valueWaiters.removeValue(forKey: characteristic) { waiter.resume(returning: nil) }
                }
            }
        }
    }

    // MARK: CBCentralManagerDelegate (on `queue`)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit("Bluetooth state", "\(central.state.rawValue)")
        if central.state != .unknown && central.state != .resetting {
            let waiters = stateWaiters
            stateWaiters.removeAll()
            waiters.forEach { $0.resume(returning: central.state) }
        }
        if central.state == .poweredOn { scan() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard let advert = FujiAdvert.parse(manufacturer: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, services: services) else { return }
        let heard = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let (changed, name): (Bool, String) = lock.withLock {
            lastSeen[peripheral.identifier] = Date()
            let previous = found[peripheral.identifier]?.1
            found[peripheral.identifier] = (peripheral, advert)
            // Some adverts carry no name; keep the last one heard.
            let oldName = names[peripheral.identifier]
            if let heard { names[peripheral.identifier] = heard }
            let name = names[peripheral.identifier] ?? "Fujifilm"
            return (previous != advert || oldName != names[peripheral.identifier], name)
        }
        if changed {
            emit("Heard", "\(name) \(advert.kind.rawValue) \(advert.tag) rssi \(rssi)")
            let known = isKnown(peripheral.identifier, tag: advert.tag)
            DispatchQueue.main.async { self.onCamera?(name, advert, known) }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectWaiter?.resume()
        connectWaiter = nil
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        busy = false
        connectWaiter?.resume(throwing: BLEError.disconnected(error.map { "\($0)" } ?? "failed to connect"))
        connectWaiter = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let why = error.map { "\($0)" } ?? "closed"
        emit("Bluetooth disconnected", why)
        let failure = BLEError.disconnected(why)
        connectWaiter?.resume(throwing: failure)
        connectWaiter = nil
        discoverWaiter?.resume(throwing: failure)
        discoverWaiter = nil
        readWaiters.values.forEach { $0.resume(throwing: failure) }
        readWaiters.removeAll()
        writeWaiters.values.forEach { $0.resume(throwing: failure) }
        writeWaiters.removeAll()
        valueWaiters.values.forEach { $0.resume(returning: nil) }
        valueWaiters.removeAll()
    }

    // MARK: CBPeripheralDelegate (on `queue`)

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        pendingServices = services.count
        if let error {
            discoverWaiter?.resume(throwing: error)
            discoverWaiter = nil
            return
        }
        if services.isEmpty {
            discoverWaiter?.resume()
            discoverWaiter = nil
        }
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for chr in service.characteristics ?? [] { characteristics[chr.uuid] = chr }
        pendingServices -= 1
        if pendingServices <= 0 {
            discoverWaiter?.resume()
            discoverWaiter = nil
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        let value = characteristic.value ?? Data()
        if pendingReads.remove(uuid) != nil, let waiter = readWaiters.removeValue(forKey: uuid) {
            if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: value) }
            return
        }
        emit("Bluetooth notify", "\(uuid.uuidString.prefix(8)) \(FujiWake.hex(value))")
        if let waiter = valueWaiters.removeValue(forKey: uuid) {
            waiter.resume(returning: value)
        } else {
            buffered[uuid] = value
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let waiter = writeWaiters.removeValue(forKey: characteristic.uuid) else { return }
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }

    // MARK: Helpers

    private func emit(_ title: String, _ detail: String) {
        sink?(title, detail)
        bridgeLog.log("ble \(title, privacy: .public): \(detail, privacy: .public)")
    }
}
