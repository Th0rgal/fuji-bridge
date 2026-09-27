import XCTest
@testable import FujiBridge

final class SessionTests: XCTestCase {
    func testBridgeSurvivesFlakyInitAndStall() async {
        let result = await run(
            .bridge,
            handles: [1, 5],
            faults: Faults(flakyHandshake: true, requireOk: true, stallChunk: true, lieAboutSize: true, impatientOpen: false),
            autoOK: true
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.reason, "imported")
        let alley = result.files.first { $0.handle == 1 }
        XCTAssertEqual(alley?.state, "full")
        XCTAssertEqual(alley?.got, alley?.total)
    }

    func testXAppStopsOnInitFail() async {
        let result = await run(
            .xapp,
            handles: [1],
            faults: Faults(flakyHandshake: true, requireOk: false, stallChunk: false, lieAboutSize: false, impatientOpen: false),
            autoOK: true
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "init-fail")
    }

    func testXAppDiscardsAStalledFile() async {
        let result = await run(
            .xapp,
            handles: [1, 2],
            faults: Faults(flakyHandshake: false, requireOk: false, stallChunk: true, lieAboutSize: false, impatientOpen: false),
            autoOK: true
        )
        XCTAssertEqual(result.reason, "stall")
        XCTAssertEqual(result.files.first { $0.handle == 2 }?.state, "lost")
    }

    func testXAppTrustsTheSizeLie() async {
        let result = await run(
            .xapp,
            handles: [1],
            faults: Faults(flakyHandshake: false, requireOk: false, stallChunk: false, lieAboutSize: true, impatientOpen: false),
            autoOK: true
        )
        XCTAssertEqual(result.reason, "truncated")
        XCTAssertEqual(result.files[0].state, "partial")
        XCTAssertEqual(result.files[0].got, 102_400)
    }

    func testCompareIsolatesFaults() async {
        let rows = await Importer.compare(frames: Array(Catalog.roll.prefix(2)))
        XCTAssertEqual(rows.count, 5)
        let flaky = rows.first { $0.id == "flaky" }
        XCTAssertEqual(flaky?.xappOk, false)
        XCTAssertEqual(flaky?.bridgeOk, true)
        let stall = rows.first { $0.id == "stall" }
        XCTAssertEqual(stall?.xappOk, false)
        XCTAssertEqual(stall?.bridgeOk, true)
        let waiting = rows.first { $0.id == "ok" }
        XCTAssertEqual(waiting?.xappOk, false)
        XCTAssertEqual(waiting?.bridgeOk, true)
    }

    func testInitPacketIs82BytesWithoutALengthPrefix() {
        let packet = Packets.initCommand(name: "Fuji Bridge")
        XCTAssertEqual(packet.count, 82)
        XCTAssertEqual(LE.u32(packet, 0), 0x52)
        XCTAssertEqual(LE.u32(packet, 4), 1)
        XCTAssertEqual(LE.u32(packet, 8), Fuji.version)
        XCTAssertEqual(LE.u32(packet, 12), 0x5d48a5ad)
        XCTAssertEqual(LE.u32(packet, 16), 0x0b7fb287)
        XCTAssertEqual(LE.u32(packet, 20), 0xd0ded5d3)
        XCTAssertEqual(LE.u32(packet, 24), 0)
        XCTAssertEqual(packet[28], 0x46)
        XCTAssertEqual(packet[29], 0)
        XCTAssertNotEqual(packet[28], 5)
        XCTAssertEqual(packet[50], 0)
    }

    func testEventsDoNotTreatTheObjectCountAsCameraState() {
        var data = Data(count: 14)
        LE.put16(&data, 0, 2)
        LE.put16(&data, 2, UInt16(Fuji.objectCount & 0xffff))
        LE.put32(&data, 4, 6)
        LE.put16(&data, 8, UInt16(Fuji.cameraState & 0xffff))
        LE.put32(&data, 10, 0)
        XCTAssertEqual(LE.u32(data, 4), 6)
        XCTAssertEqual(FujiEvents.value(data, prop: Fuji.cameraState), 0)
        XCTAssertEqual(FujiEvents.value(data, prop: Fuji.objectCount), 6)
    }

    func testObjectInfoSizeIsNotAlignedAt12() {
        let info = ObjectInfo.payload(name: "DSCF4418.JPG", bytes: 2_400_000, maxPartial: Fuji.partialMax)
        XCTAssertEqual(ObjectInfo.compressedSize(info), 2_400_000)
        XCTAssertEqual(LE.u32(info, 13), 2_400_000)
        XCTAssertNotEqual(LE.u32(info, 12), 2_400_000)
        XCTAssertEqual(LE.u32(info, 8), UInt32(Fuji.partialMax))
        XCTAssertEqual(info[52], 13)
        XCTAssertEqual(info[53], 0x44)
        XCTAssertEqual(info[54], 0)
        XCTAssertNotEqual(info[52], 0x44)
        XCTAssertEqual(ObjectInfo.filename(info), "DSCF4418.JPG")
    }

    func testImportHandlesKeepGaps() {
        let data = FujiArray.encode([4, 9])
        XCTAssertEqual(FujiArray.handles(data), [4, 9])
        XCTAssertEqual(FujiArray.handles(FujiArray.encode([])), [])
    }

    func testPartialWindowsForTheAlleyFrame() async {
        let frame = Catalog.roll[0]
        let (result, body, _) = await observe(.bridge, frames: [frame], faults: .none, autoOK: true)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(body.partials.map(\.offset), [0, 0x10_0000, 0x20_0000])
        XCTAssertEqual(body.partials.map(\.ask), [0x10_0000, 0x10_0000, 302_848])
        XCTAssertEqual(body.infoSeen.first?.compress, 2)
        // Like XApp: D227 stays 0 and the size comes from ObjectSize.
        XCTAssertEqual(body.infoSeen.first?.correct, 0)
        XCTAssertEqual(body.compressSmall, 0)
    }

    func testBodyWithoutObjectSizeFallsBackToD227() async {
        let frames = Array(Catalog.roll.prefix(2))
        let faults = Faults(flakyHandshake: false, requireOk: false, stallChunk: false, lieAboutSize: true, impatientOpen: false)
        let (result, body, lines) = await observe(.bridge, frames: frames, faults: faults, autoOK: true, objectSize: false)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.files.map(\.got), frames.map(\.bytes))
        // The first ObjectInfo lies, D227 goes on once, and every later ObjectInfo is honest.
        XCTAssertEqual(body.infoSeen.map(\.reported), [102_400, frames[0].bytes, frames[1].bytes])
        XCTAssertEqual(lines.filter { $0.dir == "OUT" && $0.title == "Set D227 = 1" }.count, 1)
        XCTAssertEqual(body.correctSize, 0)
    }

    func testResizedImportAsksTheBodyToShrinkEachFile() async {
        let frames = Array(Catalog.roll.prefix(2))
        let control = RunControl()
        control.ok = true
        let body = VirtualBody(faults: .none, control: control, frames: frames)
        var lines: [TraceLine] = []
        let result = await Importer.run(
            link: VirtualLink(body: body),
            options: RunOptions(kind: .bridge, frames: frames, faults: .none, control: control, size: .small),
            log: { lines.append($0) }
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.files.map(\.state), ["full", "full"])
        XCTAssertEqual(result.files.map(\.got), frames.map { $0.bytes / 8 })
        XCTAssertEqual(body.resizeRate, 1)
        XCTAssertEqual(body.infoSeen.first?.compress, 1)
        XCTAssertEqual(body.infoSeen.first?.correct, 1)
        // Both back to 0 once the import is over.
        XCTAssertEqual(body.compressSmall, 0)
        XCTAssertEqual(body.correctSize, 0)
    }

    func testReconnectResetsTheTransactionId() async {
        let frame = Catalog.roll[0]
        let faults = Faults(flakyHandshake: true, requireOk: false, stallChunk: true, lieAboutSize: true, impatientOpen: false)
        let (result, body, lines) = await observe(.bridge, frames: [frame], faults: faults, autoOK: true)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.files[0].state, "full")
        XCTAssertEqual(result.files[0].got, frame.bytes)
        XCTAssertEqual(body.openTids, [1, 1])
        XCTAssertEqual(lines.filter { $0.title == "Settle 50 ms" }.count, 2)
        XCTAssertEqual(body.partials[1].offset, Fuji.stallBytes)
        XCTAssertFalse(lines.isEmpty)
        // D226 is set once for the import and again after the reconnect, never around each file.
        XCTAssertEqual(lines.filter { $0.dir == "OUT" && $0.title == "Set D226 = 2" }.count, 2)
        XCTAssertEqual(lines.filter { $0.dir == "OUT" && $0.title == "Set D227 = 1" }.count, 0)
    }

    func testLiveDiscoveryUsesD621NotARange() async {
        let frames = [
            CardFrame(handle: 4, name: "DSCF4436.JPG", bytes: 1_800_000, recipe: "Velvia"),
            CardFrame(handle: 9, name: "DSCF4490.JPG", bytes: 500_000, recipe: "Acros"),
        ]
        let (result, body, _) = await observe(.bridge, frames: [], bodyFrames: frames, faults: .none, autoOK: true, live: true)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.files.map(\.handle), [9, 4])
        XCTAssertEqual(result.files.map(\.name), ["DSCF4490.JPG", "DSCF4436.JPG"])
        XCTAssertEqual(result.files[1].got, 1_800_000)
        XCTAssertEqual(result.files[0].got, 500_000)
        XCTAssertFalse(body.partials.contains { $0.handle == 1 || $0.handle == 2 })
    }

    func testLiveFallsBackToTheObjectCountWhenD621IsEmpty() async {
        let frames = Array(Catalog.roll.prefix(2))
        let (result, body, _) = await observe(
            .bridge,
            frames: [],
            bodyFrames: frames,
            faults: .none,
            autoOK: false,
            live: true,
            listed: []
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.files.map(\.handle), [2, 1])
        XCTAssertEqual(body.partials.map(\.handle), [2, 2, 1, 1, 1])
    }

    func testLiveSkipsADeadHandleAndKeepsTheNext() async {
        let frames = [
            CardFrame(handle: 4, name: "DSCF4436.JPG", bytes: 1_800_000, recipe: "Velvia"),
            CardFrame(handle: 9, name: "DSCF4490.JPG", bytes: 500_000, recipe: "Acros"),
        ]
        let (result, body, _) = await observe(
            .bridge,
            frames: [],
            bodyFrames: frames,
            faults: .none,
            autoOK: true,
            live: true,
            listed: [4, 0, 9]
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.files.map(\.state), ["full", "skipped", "full"])
        XCTAssertEqual(result.files.map(\.name), ["DSCF4490.JPG", "DSCF0000.JPG", "DSCF4436.JPG"])
        XCTAssertFalse(body.partials.contains { $0.handle == 0 })
        XCTAssertEqual(body.partials.map(\.handle), [9, 4, 4])
    }

    func testLiveReadsObjectCountWhenOkAlreadyLanded() async {
        let frames = Array(Catalog.roll.prefix(2))
        let (result, _, _) = await observe(
            .bridge,
            frames: [],
            bodyFrames: frames,
            faults: .none,
            autoOK: true,
            live: true,
            listed: []
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.reason, "imported")
        XCTAssertEqual(result.files.map(\.handle), [2, 1])
    }

    func testLiveWithNothingListedFailsClearly() async {
        let (result, _, _) = await observe(.bridge, frames: [], bodyFrames: [], faults: .none, autoOK: true, live: true)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "empty")
        XCTAssertTrue(result.summary.contains("D621"))
    }

    func testInvalidHandleIsNotInvented() async {
        let ghost = CardFrame(handle: 0, name: "NOPE.JPG", bytes: 100, recipe: "")
        let (result, body, _) = await observe(.bridge, frames: [ghost], bodyFrames: Catalog.roll, faults: .none, autoOK: true)
        XCTAssertEqual(result.reason, "object-info")
        XCTAssertEqual(result.files[0].state, "lost")
        XCTAssertTrue(body.partials.isEmpty)
    }

    func testAbortBeforeTheInit() async {
        let (result, _, lines) = await observe(.bridge, frames: [Catalog.roll[0]], faults: .none, autoOK: true, aborted: true)
        XCTAssertEqual(result.reason, "aborted")
        XCTAssertEqual(lines.last?.title, "Stopped")
    }

    func testEmptySelectionDoesNotOpen() async {
        let (result, _, lines) = await observe(.bridge, frames: [], faults: .none, autoOK: true)
        XCTAssertEqual(result.reason, "empty")
        XCTAssertTrue(lines.isEmpty)
    }

    func testXAppStillTrustsTheSizeWhenBridgeWouldNot() async {
        let faults = Faults(flakyHandshake: false, requireOk: false, stallChunk: false, lieAboutSize: true, impatientOpen: false)
        let (result, body, _) = await observe(.xapp, frames: [Catalog.roll[0]], faults: faults, autoOK: true)
        XCTAssertEqual(result.reason, "truncated")
        XCTAssertEqual(result.files[0].got, 102_400)
        XCTAssertEqual(body.infoSeen.first?.correct, 0)
        XCTAssertEqual(body.infoSeen.first?.reported, 102_400)
    }

    func testSlicedDataReadsFromItsOwnStart() {
        var data = Data([0xaa, 0xbb, 0x34, 0x12, 0x00, 0x00])
        data.removeFirst(2)
        XCTAssertNotEqual(data.startIndex, 0)
        XCTAssertEqual(LE.u32(data, 0), 0x1234)
        XCTAssertEqual(LE.u16(data, 0), 0x1234)
    }

    func testTraceTimesAreRealAndExchangesAreTimed() async {
        let (result, _, lines) = await observe(.bridge, frames: [Catalog.roll[0]], faults: .none, autoOK: true)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(lines.map(\.ms), lines.map(\.ms).sorted())
        let partials = lines.filter { $0.op == "partial" && $0.dir == "IN" }
        XCTAssertEqual(partials.count, 3)
        XCTAssertTrue(partials.allSatisfy { $0.took != nil && $0.firstByte != nil })
        XCTAssertEqual(partials.map(\.bytes).reduce(0, +), Catalog.roll[0].bytes)
        XCTAssertNotNil(lines.first { $0.op == "file" }?.took)
    }

    func testReportNamesTheStallAndTheInitFail() async {
        let faults = Faults(flakyHandshake: true, requireOk: false, stallChunk: true, lieAboutSize: false, impatientOpen: false)
        let (result, _, lines) = await observe(.bridge, frames: [Catalog.roll[0]], faults: faults, autoOK: true)
        let log = SessionLog(label: "test")
        lines.forEach(log.append)
        log.close()
        defer { try? FileManager.default.removeItem(at: log.jsonl) }
        let info = DeviceInfo(app: "t", build: "1", bundle: "b", device: "d", system: "s", lowPower: false, thermal: "nominal", path: "p")
        let report = Diagnostics.build(log: log, mode: "test", host: "virtual", environment: info, result: result)
        XCTAssertTrue(report.findings.contains { $0.title.contains("stall") })
        XCTAssertTrue(report.findings.contains { $0.title.contains("Init Fail") })
        XCTAssertEqual(report.files.first?.stalls, 1)
        XCTAssertEqual(report.copiedBytes, Catalog.roll[0].bytes)
        XCTAssertTrue(report.phases.contains { $0.op == "partial" })
        let text = Diagnostics.text(report)
        XCTAssertTrue(text.contains("PHASES"))
        XCTAssertTrue(text.contains("DSCF4418.JPG"))
    }

    func testAFileAlreadyOnThePhoneIsNotAskedAgain() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let frames = [
            CardFrame(handle: 4, name: "DSCF4436.JPG", bytes: 1_800_000, recipe: ""),
            CardFrame(handle: 9, name: "DSCF4490.JPG", bytes: 500_000, recipe: ""),
        ]
        try? Data(count: 1_800_000).write(to: dir.appendingPathComponent("DSCF4436.JPG"))
        let control = RunControl()
        control.ok = true
        let body = VirtualBody(faults: .none, control: control, frames: frames)
        let result = await Importer.run(
            link: VirtualLink(body: body),
            options: RunOptions(kind: .bridge, frames: [], faults: .none, control: control, live: true, saveDirectory: dir),
            log: { _ in }
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.files.map(\.state), ["full", "already"])
        XCTAssertEqual(body.partials.map(\.handle), [9])
    }

    func testAShortOddWindowIsRealignedBeforeTheNextRead() async {
        let frame = Catalog.roll[0]
        let control = RunControl()
        control.ok = true
        let body = VirtualBody(faults: .none, control: control, frames: [frame])
        body.shortWindow = 1_234_567 - 1_048_576
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = await Importer.run(
            link: VirtualLink(body: body),
            options: RunOptions(kind: .bridge, frames: [frame], faults: .none, control: control, saveDirectory: dir),
            log: { _ in }
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.files[0].got, frame.bytes)
        XCTAssertTrue(body.partials.dropFirst().allSatisfy { $0.offset % 512 == 0 }, "\(body.partials.map(\.offset))")
        let size = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(frame.name).path)[.size] as? Int
        XCTAssertEqual(size, frame.bytes)
    }

    func testMisalignmentIgnoresTheEndOfTheFile() {
        XCTAssertEqual(Importer.misalignment(offset: 1_048_576, total: 5_000_000), 0)
        XCTAssertEqual(Importer.misalignment(offset: 1_048_577, total: 5_000_000), 1)
        XCTAssertEqual(Importer.misalignment(offset: 4_999_999, total: 4_999_999), 0)
    }

    private func run(_ kind: ClientKind, handles: [Int], faults: Faults, autoOK: Bool) async -> RunResult {
        let frames = Catalog.roll.filter { handles.contains($0.handle) }
        let control = RunControl()
        control.ok = autoOK
        let body = VirtualBody(faults: faults, control: control, frames: frames)
        let link = VirtualLink(body: body)
        return await Importer.run(
            link: link,
            options: RunOptions(kind: kind, frames: frames, faults: faults, control: control),
            log: { _ in }
        )
    }

    private func observe(
        _ kind: ClientKind,
        frames: [CardFrame],
        bodyFrames: [CardFrame]? = nil,
        faults: Faults,
        autoOK: Bool,
        live: Bool = false,
        listed: [Int]? = nil,
        aborted: Bool = false,
        objectSize: Bool = true
    ) async -> (RunResult, VirtualBody, [TraceLine]) {
        let control = RunControl()
        control.ok = autoOK
        control.aborted = aborted
        let body = VirtualBody(faults: faults, control: control, frames: bodyFrames ?? frames)
        body.listedHandles = listed
        body.answersObjectSize = objectSize
        let link = VirtualLink(body: body)
        var lines: [TraceLine] = []
        let result = await Importer.run(
            link: link,
            options: RunOptions(kind: kind, frames: frames, faults: faults, control: control, live: live),
            log: { lines.append($0) }
        )
        return (result, body, lines)
    }
}
