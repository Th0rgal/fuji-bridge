import CoreBluetooth
import XCTest
@testable import FujiBridge

/// A secure X100VI as the GATT tables and libfuji describe it, recording what the handshake does.
final class FakeFujiGATT: GATTClient, @unchecked Sendable {
    var secure = true
    var status = Data([0x07, 0x96, 0x00, 0x00])
    var ssid = Data("FUJIFILM-X100VI-1D7B8".utf8) + Data(count: 11)
    var password = Data("s3cretpass".utf8) + Data(count: 10)
    var answer: Data? = Data([0x01, 0x00])
    var stale: Data? = nil
    /// Reads of STATUS that fail like macOS does while the user compares the pairing code.
    var pendingPairing = 0
    private(set) var steps: [String] = []
    private(set) var written: [CBUUID: Data] = [:]

    func has(_ characteristic: CBUUID) async -> Bool {
        characteristic == FujiBLE.secureStatus ? secure : true
    }

    func read(_ characteristic: CBUUID) async throws -> Data {
        if characteristic == FujiBLE.secureStatus && pendingPairing > 0 {
            pendingPairing -= 1
            throw NSError(domain: CBATTErrorDomain, code: CBATTError.insufficientEncryption.rawValue)
        }
        steps.append("read \(name(characteristic))")
        switch characteristic {
        case FujiBLE.secureStatus: return status
        case FujiBLE.ssid: return ssid
        case FujiBLE.password: return password
        default: return Data()
        }
    }

    func write(_ characteristic: CBUUID, _ value: Data) async throws {
        steps.append("write \(name(characteristic))")
        written[characteristic] = value
    }

    func subscribe(_ characteristic: CBUUID) async {
        steps.append("subscribe \(name(characteristic))")
    }

    func nextValue(_ characteristic: CBUUID, timeout: TimeInterval) async -> Data? {
        if timeout <= 0 {
            defer { stale = nil }
            return stale
        }
        steps.append("wait \(name(characteristic))")
        // Only the answer after the wake counts.
        return written[FujiBLE.wifiWake] == nil ? nil : answer
    }

    private func name(_ uuid: CBUUID) -> String {
        switch uuid {
        case FujiBLE.secureStatus: return "status"
        case FujiBLE.basicToken: return "token"
        case FujiBLE.identity: return "identity"
        case FujiBLE.ssid: return "ssid"
        case FujiBLE.password: return "password"
        case FujiBLE.wifiWake: return "wake"
        case FujiBLE.indication1: return "ind1"
        case FujiBLE.indication2: return "ind2"
        case FujiBLE.notification1: return "not1"
        default: return uuid.uuidString
        }
    }
}

final class BluetoothTests: XCTestCase {
    func testTheAdvertSeenFromThisX100VIIsABondedBodyWaitingForItsPhone() {
        // Captured on 2026-09-27 from X100VI-THOMAS, firmware 1.32, paired with XApp on an iPhone.
        let manufacturer = Data([0xd8, 0x04, 0x01, 0x31, 0x44, 0x37, 0x42, 0x38, 0x00])
        let advert = FujiAdvert.parse(manufacturer: manufacturer, services: [FujiBLE.reconnectAdvert])
        XCTAssertEqual(advert?.kind, .reconnect)
        XCTAssertEqual(advert?.tag, "1D7B8")
        XCTAssertNil(advert?.token)
        XCTAssertNil(FujiAdvert.parse(manufacturer: Data([0x4c, 0x00, 0x02]), services: []), "Apple, not Fujifilm")
    }

    func testTheSecondAdvertFromThisX100VIIsAlsoBonded() {
        // Same body a minute later, iPhone Bluetooth off: name "X100VI", 8 bytes, service 123d8f06.
        let manufacturer = Data([0xd8, 0x04, 0x01, 0x31, 0x44, 0x37, 0x42, 0x38])
        let advert = FujiAdvert.parse(manufacturer: manufacturer, services: [FujiBLE.securePairService])
        XCTAssertEqual(advert?.kind, .reconnect)
        XCTAssertEqual(advert?.tag, "1D7B8")
        let pairing = FujiAdvert.parse(manufacturer: manufacturer, services: [FujiBLE.securePairingAdvert])
        XCTAssertEqual(pairing?.kind, .securePairing)
    }

    func testBasicPairingAdvertCarriesTheToken() {
        let advert = FujiAdvert.parse(manufacturer: Data([0xd8, 0x04, 0x02, 0xde, 0xad, 0xbe, 0xef]), services: [])
        XCTAssertEqual(advert?.kind, .basicPairing)
        XCTAssertEqual(advert?.token, Data([0xde, 0xad, 0xbe, 0xef]))
    }

    func testSecureWakeFollowsLibfujiOrder() async throws {
        let gatt = FakeFujiGATT()
        gatt.stale = Data([0x00, 0x00])
        let wifi = try await FujiWake.run(gatt, token: nil) { _, _ in }
        XCTAssertEqual(wifi, CameraWifi(ssid: "FUJIFILM-X100VI-1D7B8", password: "s3cretpass"))
        XCTAssertEqual(gatt.steps, [
            "read status", "write status", "write identity",
            "subscribe ind1", "subscribe ind2", "subscribe not1", "subscribe ssid",
            "read ssid", "write wake", "read password", "wait ind1",
        ])
        XCTAssertEqual(gatt.written[FujiBLE.secureStatus], Data([0x07, 0x96, 0x00, 0x20]))
        XCTAssertEqual(gatt.written[FujiBLE.wifiWake], Data([0x04, 0x00]))
        XCTAssertEqual(gatt.written[FujiBLE.identity], Data("Fuji Bridge".utf8))
    }

    func testTheWakeWaitsWhileTheUserConfirmsThePairingCode() async throws {
        let gatt = FakeFujiGATT()
        gatt.pendingPairing = 3
        var lines: [String] = []
        let status = try await FujiWake.readThroughPairing(gatt, FujiBLE.secureStatus, pause: 1_000_000) { title, _ in lines.append(title) }
        XCTAssertEqual(status, gatt.status)
        XCTAssertEqual(lines, ["Pairing"])
        gatt.pendingPairing = 50
        do {
            _ = try await FujiWake.readThroughPairing(gatt, FujiBLE.secureStatus, attempts: 2, pause: 1_000_000) { _, _ in }
            XCTFail("expected to give up")
        } catch {
            XCTAssertTrue(FujiWake.isPairingPending(error))
        }
    }

    func testBasicWakeSendsTheTokenInsteadOfTheStatus() async throws {
        let gatt = FakeFujiGATT()
        gatt.secure = false
        _ = try await FujiWake.run(gatt, token: Data([1, 2, 3, 4])) { _, _ in }
        XCTAssertEqual(gatt.steps.prefix(2), ["write token", "write identity"])
        XCTAssertEqual(gatt.written[FujiBLE.basicToken], Data([1, 2, 3, 4]))
    }

    func testABusyCameraIsReported() async {
        let gatt = FakeFujiGATT()
        gatt.answer = Data([0x00, 0x00])
        do {
            _ = try await FujiWake.run(gatt, token: nil) { _, _ in }
            XCTFail("expected busy")
        } catch BLEError.busy {
        } catch {
            XCTFail("\(error)")
        }
    }

    func testNoAnswerStillReturnsTheNetwork() async throws {
        let gatt = FakeFujiGATT()
        gatt.answer = nil
        let wifi = try await FujiWake.run(gatt, token: nil) { _, _ in }
        XCTAssertEqual(wifi.ssid, "FUJIFILM-X100VI-1D7B8")
    }

    // MARK: What the card says when an import stops

    @MainActor
    func testBluetoothOffAndDeniedAreNamed() {
        XCTAssertEqual(BenchModel.hint(ble: BLEError.off, localNetworkDenied: false)?.title, "Bluetooth is off")
        XCTAssertEqual(BenchModel.hint(ble: BLEError.unauthorized, localNetworkDenied: false)?.title, "Bluetooth is not allowed")
        // The camera itself being away is not something the hint can name.
        XCTAssertNil(BenchModel.hint(ble: BLEError.notFound, localNetworkDenied: false))
        XCTAssertNil(BenchModel.hint(ble: nil, localNetworkDenied: false))
    }

    @MainActor
    func testWifiJoinFailuresAndLocalNetworkAreNamed() {
        XCTAssertEqual(BenchModel.hint(ble: WifiJoin.Failure.declined("FUJIFILM-X100VI-1234"), localNetworkDenied: false)?.title, "Wi-Fi join cancelled")
        XCTAssertEqual(BenchModel.hint(ble: WifiJoin.Failure.notJoined("FUJIFILM-X100VI-1234"), localNetworkDenied: false)?.title, "Could not join FUJIFILM-X100VI-1234")
        // Local Network wins: the join worked, the socket was blocked.
        XCTAssertEqual(BenchModel.hint(ble: nil, localNetworkDenied: true)?.title, "Local Network access is off")
    }

    func testPowerStates() {
        XCTAssertEqual(BluetoothPower(.poweredOff), .off)
        XCTAssertEqual(BluetoothPower(.unauthorized), .denied)
        XCTAssertEqual(BluetoothPower(.poweredOn), .on)
        XCTAssertEqual(BluetoothPower(.resetting), .unknown)
    }

    func testNotOnTheCameraNetworkByDefault() {
        // The test host is never on 192.168.0.x from the camera: the join check must say no rather than guess.
        XCTAssertFalse(WifiJoin.hasAddress(near: "10.254.254.1"))
    }
}
