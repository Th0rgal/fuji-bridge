import CoreBluetooth
import XCTest
@testable import FujiBridge

/// A camera's Bluetooth side for the settings backup: scripted notifications, chunks pulled by reads.
private final class FakeBackupCamera: GATTClient, @unchecked Sendable {
    var ready: UInt8 = 1
    var chunks: [Data] = []
    var information = Data()
    var writes: [(CBUUID, Data)] = []
    private var states: [Data] = []
    private var readIndex = 0

    func has(_ characteristic: CBUUID) async -> Bool { true }
    func subscribe(_ characteristic: CBUUID) async {}

    func write(_ characteristic: CBUUID, _ value: Data) async throws {
        writes.append((characteristic, value))
        if characteristic == FujiBLE.fileIndex {
            // One "transferring" notify per chunk, then "file finished".
            states = chunks.indices.map { Data([$0 == 0 ? 1 : 2, 0, UInt8($0 & 0xff), 0]) } + [Data([3, 0, 0, 0])]
        }
    }

    func nextValue(_ characteristic: CBUUID, timeout: TimeInterval) async -> Data? {
        if characteristic == FujiBLE.backupState { return Data([ready, 0]) }
        if characteristic == FujiBLE.fileTransactionState, !states.isEmpty { return states.removeFirst() }
        return nil
    }

    func read(_ characteristic: CBUUID) async throws -> Data {
        if characteristic == FujiBLE.fileInformation { return information }
        defer { readIndex += 1 }
        return chunks[readIndex]
    }

    static func chunk(seq: UInt16, _ payload: [UInt8]) -> Data {
        let n = UInt32(payload.count)
        return Data([UInt8(seq & 0xff), UInt8(seq >> 8), UInt8(n & 0xff), UInt8(n >> 8 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 24)] + payload)
    }
}

final class SettingsBackupTests: XCTestCase {
    func testABackupIsReassembledAndChecked() async throws {
        let camera = FakeBackupCamera()
        let first = [UInt8](repeating: 7, count: 120)
        let last: [UInt8] = [1, 2, 3, 4]
        let sum = (first + last).reduce(0) { $0 + Int($1) } & 0xffff
        camera.chunks = [
            FakeBackupCamera.chunk(seq: 0, first),
            FakeBackupCamera.chunk(seq: 0xffff, last + [UInt8(sum & 0xff), UInt8(sum >> 8)]),
        ]
        var info = Data("backup.dat".utf8) + Data(count: 30)
        info += Data([124, 0, 0, 0])
        camera.information = info
        let result = try await FujiBackup.run(camera, log: { _, _ in })
        XCTAssertEqual(result.name, "backup.dat")
        XCTAssertEqual(Array(result.data), first + last)
        XCTAssertEqual(camera.writes.first?.1, Data([1, 0]))
        XCTAssertEqual(camera.writes.last.map { $0.0 }, FujiBLE.fileTransferResult)
        XCTAssertEqual(camera.writes.last?.1, Data([3, 0]))
    }

    func testADamagedBackupIsRefused() async {
        let camera = FakeBackupCamera()
        camera.chunks = [FakeBackupCamera.chunk(seq: 0xffff, [9, 9, 0x00, 0x00])]
        do {
            _ = try await FujiBackup.run(camera, log: { _, _ in })
            XCTFail("a wrong checksum must fail")
        } catch {
            XCTAssertEqual(camera.writes.last?.1, Data([0, 0]))
        }
    }

    func testABusyCameraSaysSo() async {
        let camera = FakeBackupCamera()
        camera.ready = 0
        do {
            _ = try await FujiBackup.run(camera, log: { _, _ in })
            XCTFail("busy")
        } catch let failure as FujiBackup.Failure {
            if case .busy = failure {} else { XCTFail("\(failure)") }
        } catch {
            XCTFail("\(error)")
        }
    }
}

final class RecipeReaderTests: XCTestCase {
    /// A minimal JPEG: SOI, an Exif APP1 with IFD0 → ExifIFD → a Fujifilm MakerNote, EOI.
    private func jpeg(note entries: [(UInt16, UInt16, [UInt8])]) -> Data {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
        func u32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)] }
        // MakerNote: "FUJIFILM", IFD offset 12, then the IFD with inline values (all 4 bytes or less here).
        var note: [UInt8] = Array("FUJIFILM".utf8) + u32(12) + u16(entries.count)
        for (tag, type, value) in entries {
            let size = [3: 2, 4: 4, 9: 4][Int(type)] ?? 1
            note += u16(Int(tag)) + u16(Int(type)) + u32(value.count / size) + (value + [UInt8](repeating: 0, count: 4)).prefix(4)
        }
        note += u32(0)
        // TIFF: header (8), IFD0 at 8 with one entry (ExifIFD pointer), Exif IFD at 26 with one entry (MakerNote).
        let exifIFD = 8 + 2 + 12 + 4
        let noteAt = exifIFD + 2 + 12 + 4
        var tiff: [UInt8] = [0x49, 0x49, 0x2a, 0x00] + u32(8)
        tiff += u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(exifIFD) + u32(0)
        tiff += u16(1) + u16(0x927c) + u16(7) + u32(note.count) + u32(noteAt) + u32(0)
        tiff += note
        let app1 = Array("Exif\0\0".utf8) + tiff
        return Data([0xff, 0xd8, 0xff, 0xe1] + [UInt8((app1.count + 2) >> 8), UInt8((app1.count + 2) & 0xff)] + app1 + [0xff, 0xd9])
    }

    func testTheX100VIRecipeReadsBack() throws {
        func s32(_ v: Int) -> [UInt8] { let u = UInt32(bitPattern: Int32(v)); return [UInt8(u & 0xff), UInt8(u >> 8 & 0xff), UInt8(u >> 16 & 0xff), UInt8(u >> 24)] }
        // Values as found in a real X100VI JPEG (DSCF1710): Classic Chrome, DR400, H −1, S −1, …
        let data = jpeg(note: [
            (0x1001, 3, [0x02, 0]), (0x1002, 3, [0, 0]), (0x1003, 3, [0x00, 0x01]), (0x100e, 3, [0xe0, 0x02]),
            (0x1040, 9, s32(16)), (0x1041, 9, s32(16)), (0x1047, 9, s32(32)), (0x1048, 9, s32(64)),
            (0x104c, 3, [16, 0]), (0x104e, 9, s32(32)), (0x1401, 3, [0x00, 0x06]), (0x1402, 3, [1, 0]), (0x1403, 3, [0x90, 0x01]),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recipe-\(UUID().uuidString).jpg")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let recipe = try XCTUnwrap(RecipeReader.read(url).recipe)
        XCTAssertEqual(recipe.film, "Classic Chrome")
        XCTAssertEqual(recipe.dynamicRange, "DR400")
        XCTAssertEqual(recipe.highlight, "−1")
        XCTAssertEqual(recipe.shadow, "−1")
        XCTAssertEqual(recipe.color, "+2")
        XCTAssertEqual(recipe.sharpness, "−2")
        XCTAssertEqual(recipe.noiseReduction, "−4")
        XCTAssertEqual(recipe.grain, "Weak Small")
        XCTAssertEqual(recipe.colorChrome, "Strong")
        XCTAssertEqual(recipe.colorChromeBlue, "Weak")
        XCTAssertEqual(recipe.whiteBalance, "Auto")
    }

    func testBatteryLevels() {
        XCTAssertEqual(IO.batteryFraction(multi: 11, level: nil), 1.0)
        XCTAssertEqual(IO.batteryFraction(multi: 8, level: 3), 0.4)
        XCTAssertEqual(IO.batteryFraction(multi: nil, level: 3), 1.0)
        XCTAssertNil(IO.batteryFraction(multi: nil, level: nil))
    }
}
