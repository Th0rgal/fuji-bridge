import XCTest
@testable import FujiBridge

/// Streaming to .part files, resuming across runs, the speed test and the report's transfer numbers.
final class TransferTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func run(_ frames: [CardFrame], faults: Faults = .none, benchmark: [Int]? = nil, window: Int = Fuji.partialMax) async -> (RunResult, VirtualBody, [TraceLine]) {
        let control = RunControl()
        control.ok = true
        let body = VirtualBody(faults: faults, control: control, frames: frames)
        var lines: [TraceLine] = []
        let result = await Importer.run(
            link: VirtualLink(body: body),
            options: RunOptions(kind: .bridge, frames: frames, faults: faults, control: control, saveDirectory: dir, window: window, benchmark: benchmark),
            log: { lines.append($0) }
        )
        return (result, body, lines)
    }

    func testFilesStreamToDiskAndLeaveNoPart() async throws {
        let frame = Catalog.roll[0]
        let (result, _, _) = await run([frame])
        XCTAssertTrue(result.ok)
        let saved = dir.appendingPathComponent(frame.name)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? Int, frame.bytes)
        XCTAssertTrue(PartFile.parts(of: frame.name, in: dir).isEmpty)
    }

    func testAPartFromAnEarlierRunIsResumed() async throws {
        let frame = Catalog.roll[0]
        // 1.5 MB already here, plus 100 bytes of a window that was cut: the tail is dropped to stay aligned.
        let kept = 3 * 512 * 1024 + 100
        let part = dir.appendingPathComponent(PartFile.partName(frame.name, total: frame.bytes))
        var head = Data(count: kept)
        head[0] = 0xff
        head[1] = 0xd8
        try head.write(to: part)
        let (result, body, lines) = await run([frame])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.files[0].state, "full")
        XCTAssertEqual(body.partials.first?.offset, 3 * 512 * 1024)
        XCTAssertTrue(lines.contains { $0.title == "Resuming \(frame.name)" })
        let saved = dir.appendingPathComponent(frame.name)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? Int, frame.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertEqual(Diagnostics.transferStat(lines)?.resumedBytes, 3 * 512 * 1024)
    }

    func testAHalfJPEGIsNotKeptAndABrokenCopyIsFetchedAgain() async throws {
        XCTAssertTrue(JPEGCheck.complete(try write(Data.jpeg(count: 5000), "A.JPG")))
        XCTAssertFalse(JPEGCheck.complete(try write(Data.jpeg(count: 5000).prefix(3000), "B.JPG")))
        XCTAssertTrue(JPEGCheck.complete(try write(Data(count: 10), "C.RAF")))
        // A copy cut short by an older build, with the right size: fetched again, not "already here".
        let frame = Catalog.roll[0]
        var broken = Data.jpeg(count: frame.bytes)
        broken[frame.bytes - 1] = 0
        _ = try write(broken, frame.name)
        let (result, body, _) = await run([frame])
        XCTAssertEqual(result.files[0].state, "full")
        XCTAssertFalse(body.partials.isEmpty)
        XCTAssertTrue(JPEGCheck.complete(dir.appendingPathComponent(frame.name)))
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testAPartForAnotherSizeIsThrownAway() async throws {
        let frame = Catalog.roll[0]
        let stale = dir.appendingPathComponent(PartFile.partName(frame.name, total: frame.bytes / 8))
        try Data(count: 4096).write(to: stale)
        let (result, body, _) = await run([frame])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(body.partials.first?.offset, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testAStallMidFileResumesFromDiskAndCountsInTheReport() async throws {
        let frame = Catalog.roll[0]
        let faults = Faults(flakyHandshake: false, requireOk: false, stallChunk: true, lieAboutSize: false, impatientOpen: false)
        let (result, _, lines) = await run([frame], faults: faults)
        XCTAssertTrue(result.ok)
        let saved = dir.appendingPathComponent(frame.name)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? Int, frame.bytes)
        let transfer = try XCTUnwrap(Diagnostics.transferStat(lines))
        XCTAssertEqual(transfer.reconnects, 1)
        XCTAssertGreaterThan(transfer.windows, 0)
        XCTAssertGreaterThan(transfer.wireMBps, 0)
    }

    func testTheWindowSizeIsHonoured() async {
        let frame = Catalog.roll[0]
        let (result, body, _) = await run([frame], window: 512 * 1024)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(body.partials.first?.ask, 512 * 1024)
    }

    func testSpeedTestReadsEachWindowSizeAndSavesNothing() async throws {
        let frame = Catalog.roll[0]
        let sizes = [512 * 1024, 1_048_576, 2 * 1_048_576]
        let (result, body, lines) = await run([frame], benchmark: sizes)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.reason, "benchmarked")
        XCTAssertEqual(Set(body.partials.map(\.ask)).isSuperset(of: [512 * 1024, 1_048_576]), true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(frame.name).path))
        let bench = try XCTUnwrap(Diagnostics.transferStat(lines)?.bench)
        XCTAssertEqual(bench.map(\.window), sizes.map { ByteFormat.string($0) })
        XCTAssertTrue(bench.allSatisfy { $0.ok && $0.bytes == frame.bytes })
        XCTAssertEqual(body.compressSmall, 0)
    }
}

extension Data {
    /// Zeros with a JPEG's start and end markers, enough for the importer's completeness check.
    static func jpeg(count: Int) -> Data { jpegShaped(Data(count: count)) }

    static func jpegShaped(_ data: Data) -> Data {
        var data = data
        guard data.count >= 4 else { return data }
        data[0] = 0xff; data[1] = 0xd8
        data[data.count - 2] = 0xff; data[data.count - 1] = 0xd9
        return data
    }
}

/// Name, size and date by object property instead of GetObjectInfo (500–700 ms a file on an X100VI).
final class ObjectPropsTests: XCTestCase {
    func testImportAndListingSkipGetObjectInfoWhenTheBodyAnswersProperties() async {
        let frames = Array(Catalog.roll.prefix(3))
        let control = RunControl()
        control.ok = true
        let body = VirtualBody(faults: .none, control: control, frames: frames)
        body.answersObjectProps = true
        let result = await Importer.run(link: VirtualLink(body: body), options: RunOptions(kind: .bridge, frames: frames, faults: .none, control: control), log: { _ in })
        XCTAssertTrue(result.ok, result.summary)
        XCTAssertEqual(result.files.map(\.state), ["full", "full", "full"])
        XCTAssertEqual(result.files.map(\.got), frames.map(\.bytes))
        XCTAssertTrue(body.infoSeen.isEmpty, "GetObjectInfo was still asked")

        let photos = Box<[CardPhoto]>([])
        let listed = await Importer.run(link: VirtualLink(body: body), options: RunOptions(kind: .bridge, frames: frames, faults: .none, control: control, preview: { photos.value.append($0) }), log: { _ in })
        XCTAssertTrue(listed.ok, listed.summary)
        XCTAssertEqual(photos.value.map(\.name), frames.map(\.name))
        XCTAssertEqual(photos.value.first?.captured, "20260924T195324")
        XCTAssertTrue(body.infoSeen.isEmpty)
    }

    func testABodyWithoutPropertiesFallsBackOnceAndStays() async {
        let frames = Array(Catalog.roll.prefix(3))
        let control = RunControl()
        control.ok = true
        let body = VirtualBody(faults: .none, control: control, frames: frames)
        var lines: [TraceLine] = []
        let result = await Importer.run(link: VirtualLink(body: body), options: RunOptions(kind: .bridge, frames: frames, faults: .none, control: control), log: { lines.append($0) })
        XCTAssertTrue(result.ok, result.summary)
        XCTAssertEqual(body.infoSeen.count, 3)
        XCTAssertEqual(lines.filter { $0.dir == "OUT" && $0.title.hasPrefix("ObjectFileName") }.count, 1)
    }

    func testPTPStringsRoundTrip() {
        XCTAssertEqual(PTPString.decode(PTPString.encode("DSCF4418.JPG")), "DSCF4418.JPG")
        XCTAssertNil(PTPString.decode(Data()))
        XCTAssertNil(PTPString.decode(Data([0])))
    }
}

/// The Wi-Fi session kept open between actions: browse, then import, without a second handshake.
final class KeptSessionTests: XCTestCase {
    func testASecondRunReusesTheSessionWithoutAHandshake() async throws {
        let frames = Array(Catalog.roll.prefix(2))
        let control = RunControl()
        control.ok = true
        let body = VirtualBody(faults: .none, control: control, frames: frames)
        let link = VirtualLink(body: body)
        var first: [TraceLine] = []
        let listed = await Importer.session(
            link: link,
            options: RunOptions(kind: .bridge, frames: frames, faults: .none, control: control, preview: { _ in }, keepOpen: true),
            log: { first.append($0) }
        )
        XCTAssertTrue(listed.result.ok, listed.result.summary)
        let live = try XCTUnwrap(listed.live)
        XCTAssertEqual(body.openTids, [1])
        let alive = await Importer.probe(live)
        XCTAssertTrue(alive)

        var second: [TraceLine] = []
        let imported = await Importer.session(
            link: live.link,
            options: RunOptions(kind: .bridge, frames: [frames[1]], faults: .none, control: control, keepOpen: true, reuse: live),
            log: { second.append($0) }
        )
        XCTAssertTrue(imported.result.ok, imported.result.summary)
        XCTAssertEqual(imported.result.files.map(\.state), ["full"])
        // No second OpenSession, no init: the first line of the new run says the session was reused.
        XCTAssertEqual(body.openTids, [1])
        XCTAssertTrue(second.contains { $0.title == "Session reused" })
        XCTAssertFalse(second.contains { $0.op == "init" })
        XCTAssertNotNil(imported.live)
    }

    func testAFailedRunDoesNotKeepTheSession() async {
        let control = RunControl()
        control.ok = true
        let body = VirtualBody(faults: .none, control: control, frames: [])
        let outcome = await Importer.session(
            link: VirtualLink(body: body),
            options: RunOptions(kind: .bridge, frames: [Catalog.roll[0]], faults: .none, control: control, keepOpen: true),
            log: { _ in }
        )
        XCTAssertFalse(outcome.result.ok)
        XCTAssertNil(outcome.live)
    }
}
