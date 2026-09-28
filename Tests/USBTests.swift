import XCTest
@testable import FujiBridge

/// A body answering plain USB PTP, the way the X100VI does in USB mode: standard ObjectInfo (size at 8,
/// format at 4), folders among the handles, and 0x200A for every Fuji Wi-Fi prop.
@MainActor
final class FakeUSBCamera: PTPCamera, @unchecked Sendable {
    var sink: (@Sendable (String, String) -> Void)?
    let files: [(handle: UInt32, name: String, bytes: Data)]
    let folders: [UInt32] = [1, 2]
    var reads: [(handle: UInt32, offset: Int, ask: Int)] = []
    var codes: [UInt16] = []
    /// Next GetPartialObject answers this many bytes, like a body cutting a window short.
    var shortWindow: Int?

    init(files: [(UInt32, String, Int)]) {
        self.files = files.map { handle, name, count in
            (handle, name, Data.jpegShaped(Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(handle)) })))
        }
    }

    func openSession(timeout: TimeInterval) async throws {
        sink?("USB session open", "fake")
    }

    func send(_ command: Data, out: Data?) async throws -> (Data, Data) {
        let code = Packets.ptpCode(command)
        let tid = LE.u32(command, 8)
        let params = stride(from: 12, to: command.count, by: 4).map { LE.u32(command, $0) }
        codes.append(code)
        func reply(_ data: Data, _ rc: UInt16 = Fuji.ok) -> (Data, Data) {
            (data, Packets.response(code: code, tid: tid, rc: rc))
        }
        switch code {
        case Fuji.getDeviceInfo:
            return reply(Data(count: 40))
        case Fuji.getObjectHandles:
            return reply(FujiArray.encode((folders + files.map(\.handle)).map(Int.init)))
        case Fuji.getObjectInfo:
            let handle = params.first ?? 0
            var info = Data(count: 208)
            if folders.contains(handle) {
                LE.put16(&info, 4, 0x3001)
                return reply(info)
            }
            guard let file = files.first(where: { $0.handle == handle }) else { return reply(Data(), Fuji.invalidObject) }
            LE.put16(&info, 4, 0x3801)
            LE.put32(&info, 8, UInt32(file.bytes.count))
            info[52] = UInt8(file.name.utf16.count + 1)
            for (i, unit) in file.name.utf16.enumerated() { LE.put16(&info, 53 + i * 2, unit) }
            return reply(info)
        case Fuji.getPartial:
            guard let file = files.first(where: { $0.handle == params[0] }) else { return reply(Data(), Fuji.invalidObject) }
            let offset = Int(params[1])
            var ask = Int(params[2])
            if let short = shortWindow { shortWindow = nil; ask = short }
            reads.append((params[0], offset, ask))
            let end = min(file.bytes.count, offset + ask)
            return reply(file.bytes.subdata(in: offset..<end))
        case Fuji.getProp, Fuji.setProp:
            return reply(Data(), 0x200a)
        default:
            return reply(Data())
        }
    }
}

final class USBTests: XCTestCase {
    @MainActor
    func testUSBImportUsesPlainPTPAndTheSharedFileLoop() async throws {
        let camera = FakeUSBCamera(files: [(10, "DSCF0010.JPG", 2_500_001), (11, "DSCF0011.JPG", 300_000), (12, "DSCF0012.JPG", 1_048_576)])
        camera.shortWindow = 777_777
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var lines: [TraceLine] = []
        let result = await Importer.run(
            link: USBLink(cameras: camera, timeout: 5),
            options: RunOptions(kind: .bridge, frames: [], faults: .none, control: RunControl(), live: true, saveDirectory: dir, transport: .usb, latest: 3),
            log: { lines.append($0) }
        )
        XCTAssertTrue(result.ok, result.summary)
        XCTAssertEqual(result.files.map(\.name), ["DSCF0012.JPG", "DSCF0011.JPG", "DSCF0010.JPG"])
        XCTAssertEqual(result.files.map(\.state), ["full", "full", "full"])
        for file in camera.files {
            XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(file.name)), file.bytes, file.name)
        }
        // No Wi-Fi handshake, no Fuji props, no OK wait.
        XCTAssertFalse(camera.codes.contains(Fuji.openSession))
        XCTAssertFalse(camera.codes.contains(Fuji.setProp))
        XCTAssertFalse(camera.codes.contains(Fuji.getProp))
        XCTAssertFalse(lines.contains { $0.op == "ok-wait" || $0.op == "init" })
        // The short odd window was realigned before the next read.
        XCTAssertTrue(camera.reads.allSatisfy { $0.offset % 512 == 0 }, "\(camera.reads.map(\.offset))")
        XCTAssertTrue(lines.contains { $0.title.hasPrefix("Realigned") })
    }

    @MainActor
    func testUSBNewestOnlyAndAlreadyHere() async throws {
        let camera = FakeUSBCamera(files: [(10, "A.JPG", 1000), (11, "B.JPG", 2000), (12, "C.JPG", 3000)])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data.jpeg(count: 3000).write(to: dir.appendingPathComponent("C.JPG"))
        let result = await Importer.run(
            link: USBLink(cameras: camera, timeout: 5),
            options: RunOptions(kind: .bridge, frames: [], faults: .none, control: RunControl(), live: true, saveDirectory: dir, transport: .usb, latest: 2),
            log: { _ in }
        )
        XCTAssertTrue(result.ok, result.summary)
        XCTAssertEqual(result.files.map(\.name), ["C.JPG", "B.JPG"])
        XCTAssertEqual(result.files.map(\.state), ["already", "full"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("A.JPG").path))
    }

    @MainActor
    func testBrowseListsThumbnailsWithoutCopyingAndSelectionImportsOnlyThose() async throws {
        let camera = FakeUSBCamera(files: [(10, "A.JPG", 5000), (11, "B.JPG", 6000), (12, "C.JPG", 7000)])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = Seen()
        let browse = await Importer.run(
            link: USBLink(cameras: camera, timeout: 5),
            options: RunOptions(kind: .bridge, frames: [], faults: .none, control: RunControl(), live: true, saveDirectory: dir,
                                transport: .usb, latest: 2, preview: { seen.add($0) }),
            log: { _ in }
        )
        XCTAssertTrue(browse.ok)
        XCTAssertEqual(browse.reason, "previewed")
        XCTAssertEqual(seen.photos.map(\.name), ["C.JPG", "B.JPG"])
        XCTAssertEqual(seen.photos.map(\.bytes), [7000, 6000])
        XCTAssertTrue(camera.codes.contains(Fuji.getThumb))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])

        let picked = await Importer.run(
            link: USBLink(cameras: camera, timeout: 5),
            options: RunOptions(kind: .bridge, frames: [], faults: .none, control: RunControl(), live: true, saveDirectory: dir,
                                transport: .usb, latest: 25, only: [10]),
            log: { _ in }
        )
        XCTAssertTrue(picked.ok, picked.summary)
        XCTAssertEqual(picked.files.map(\.name), ["A.JPG"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["A.JPG"])
    }

    func testExifOrientationFromTheFileHead() throws {
        // SOI, APP1 "Exif\0\0", little-endian TIFF, IFD0 with one entry: Orientation = 8.
        var head: [UInt8] = [0xff, 0xd8, 0xff, 0xe1, 0x00, 0x22]
        head += Array("Exif".utf8) + [0, 0]
        head += [0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00]
        head += [0x01, 0x00, 0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00]
        head += [0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(Exif.orientation(Data(head)), 8)
        XCTAssertNil(Exif.orientation(Data([0xff, 0xd8, 0xff, 0xda, 0x00, 0x02])))
        let captured = "20260924T195324"
        var info = Data(count: 120)
        info[52] = 2
        LE.put16(&info, 53, 0x41)
        info[57] = UInt8(captured.utf16.count + 1)
        for (i, unit) in captured.utf16.enumerated() { LE.put16(&info, 58 + i * 2, unit) }
        XCTAssertEqual(ObjectInfo.captureDate(info), captured)
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [CardPhoto] = []
    var photos: [CardPhoto] { lock.lock(); defer { lock.unlock() }; return store }
    func add(_ photo: CardPhoto) { lock.lock(); store.append(photo); lock.unlock() }
}
