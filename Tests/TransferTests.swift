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
        try Data(count: kept).write(to: part)
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
