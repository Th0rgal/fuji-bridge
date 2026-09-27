import Foundation
import Network
import OSLog
import UIKit

// Every run leaves three files in Documents/Diagnostics, readable in the Files app and shareable
// from the Diagnostics screen:
//   <stamp>.jsonl  one trace line per row, written as it happens, so a hang or a kill still leaves it
//   <stamp>.txt    the report: phases, slowest exchanges, per-file speed, what looked wrong
//   <stamp>.json   the same report plus the whole trace, for scripts

let bridgeLog = Logger(subsystem: "md.thomas.fujibridge", category: "session")

/// Thread-safe recorder for one run. Lines come from the importer and from Network.framework's queue.
final class SessionLog: @unchecked Sendable {
    let stamp: String
    let started: Date
    let jsonl: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var store: [TraceLine] = []
    private var extraSeq = 1_000_000
    let origin = DispatchTime.now().uptimeNanoseconds

    init(label: String) {
        started = Date()
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd-HHmmss"
        stamp = format.string(from: started) + "-" + label
        jsonl = Diagnostics.folder().appendingPathComponent(stamp + ".jsonl")
        FileManager.default.createFile(atPath: jsonl.path, contents: nil)
        handle = try? FileHandle(forWritingTo: jsonl)
    }

    var lines: [TraceLine] {
        lock.lock()
        defer { lock.unlock() }
        return store
    }

    func append(_ line: TraceLine) {
        lock.lock()
        store.append(line)
        if let data = try? Diagnostics.encoder(pretty: false).encode(line) {
            handle?.write(data + Data([0x0a]))
        }
        lock.unlock()
        let took = line.took.map { String(format: " (%.1f ms)", $0) } ?? ""
        bridgeLog.log("\(line.dir, privacy: .public) \(line.op, privacy: .public) \(line.title, privacy: .public)\(took, privacy: .public) \(line.detail, privacy: .public)")
    }

    /// App-side events (lifecycle, memory, path) that the importer does not see.
    func event(_ title: String, _ detail: String, op: String = "app", level: String = "info") {
        lock.lock()
        extraSeq += 1
        let id = extraSeq
        lock.unlock()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - origin) / 1_000_000
        append(TraceLine(id: id, ms: ms, dir: "APP", title: title, detail: detail, hex: "", level: level, op: op))
    }

    func close() {
        lock.lock()
        try? handle?.close()
        handle = nil
        lock.unlock()
    }
}

struct DeviceInfo: Codable, Sendable {
    var app: String
    var build: String
    var bundle: String
    var device: String
    var system: String
    var lowPower: Bool
    var thermal: String
    var path: String
    var platform: String = ""

    @MainActor
    static func snapshot(path: String) -> DeviceInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        // hw.machine is iPhone16,1 on a phone and arm64 on a Mac; hw.model names the Mac (Mac14,2).
        let machine = ProcessInfo.processInfo.isMacCatalystApp ? sysctl("hw.model") : sysctl("hw.machine")
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return DeviceInfo(
            app: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?",
            bundle: Bundle.main.bundleIdentifier ?? "?",
            // Under Catalyst UIDevice answers "iPad" and "iPadOS"; ask the process for the real system.
            device: ProcessInfo.processInfo.isMacCatalystApp ? "Mac \(machine)" : "\(UIDevice.current.model) \(machine)",
            system: ProcessInfo.processInfo.isMacCatalystApp ? macOSVersion : "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: thermal,
            path: path,
            platform: platformName
        )
    }

    /// Same binary, three ways to run it. The report says which one produced it.
    static var platformName: String {
        let process = ProcessInfo.processInfo
        if process.isMacCatalystApp { return process.isiOSAppOnMac ? "iOS app on Mac" : "Mac (Catalyst)" }
        #if targetEnvironment(simulator)
        return "iOS Simulator"
        #else
        return "iOS"
        #endif
    }

    private static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &bytes, &size, nil, 0)
        return String(cString: bytes)
    }
}

struct OpStat: Codable, Sendable, Equatable {
    var op: String
    var count: Int
    var totalMs: Double
    var avgMs: Double
    var p50Ms: Double
    var p95Ms: Double
    var maxMs: Double
    var bytes: Int
}

struct FileStat: Codable, Sendable, Equatable {
    var name: String
    var bytes: Int
    var state: String
    var totalMs: Double
    var transferMs: Double
    var overheadMs: Double
    var mbPerSecond: Double
    var chunks: Int
    var firstByteAvgMs: Double
    var stalls: Int
}

/// How the bytes actually moved, over every window of the run. What to look at before touching the protocol.
struct TransferStat: Codable, Sendable, Equatable {
    /// GetPartialObject exchanges that delivered data, and what they delivered.
    var windows: Int
    var bytes: Int
    /// Bytes over time spent inside the windows: the pipe itself.
    var wireMBps: Double
    /// Bytes over the whole stretch from the first window to the last, reconnects and props included.
    var effectiveMBps: Double
    var windowMBpsP10: Double
    var windowMBpsP50: Double
    var windowMBpsP90: Double
    /// Command to first byte: the camera's latency per window.
    var firstByteP50Ms: Double
    var firstByteP95Ms: Double
    var firstByteMaxMs: Double
    /// Longest silence inside a window once bytes flowed: radio dropouts. Zero over USB.
    var gapP50Ms: Double
    var gapP95Ms: Double
    var gapMaxMs: Double
    var receivesPerWindow: Double
    var reconnects: Int
    var reconnectMs: Double
    /// Windows that died, and bytes asked for twice (realigned tails).
    var failedWindows: Int
    var resentBytes: Int
    /// Bytes that came from .part files of earlier runs instead of the camera.
    var resumedBytes: Int
    /// MB/s in each 5 s slice of the transfer, from the first window on.
    var timeline: [Double]
    var bench: [BenchStat]
}

struct BenchStat: Codable, Sendable, Equatable {
    var window: String
    var ok: Bool
    var bytes: Int
    var ms: Double
    var mbps: Double
    var firstByteP50Ms: Double
}

struct Finding: Codable, Sendable, Equatable {
    var severity: String
    var title: String
    var detail: String
}

struct Report: Codable, Sendable {
    var stamp: String
    var started: Date
    var mode: String
    var host: String
    var environment: DeviceInfo
    var result: RunResult
    var durationMs: Double
    var copiedBytes: Int
    var averageMBps: Double
    var phases: [OpStat]
    var slowest: [TraceLine]
    var files: [FileStat]
    var transfer: TransferStat?
    var findings: [Finding]
    var lines: [TraceLine]
}

enum Diagnostics {
    static func folder() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    static func build(log: SessionLog, mode: String, host: String, environment: DeviceInfo, result: RunResult) -> Report {
        let lines = log.lines.sorted { $0.ms < $1.ms }
        let duration = lines.last?.ms ?? 0

        // Exchanges that close with a duration. OUT lines only open them.
        let timed = lines.filter { $0.took != nil && $0.dir != "OUT" }
        var phases: [OpStat] = []
        // "-total", "file" and "done" lines sum up a stretch of the lines around them; they get their own rows.
        let order = ["connect", "init", "settle", "open", "ok-wait", "ok-wait-total", "setup", "setup-total", "prep", "info", "partial", "save", "file", "reconnect", "reconnect-total", "done"]
        let grouped = Dictionary(grouping: timed.filter { !$0.op.isEmpty }, by: \.op)
        for op in order + grouped.keys.filter({ !order.contains($0) }).sorted() {
            guard let group = grouped[op], !group.isEmpty else { continue }
            let values = group.compactMap(\.took).sorted()
            let total = values.reduce(0, +)
            phases.append(OpStat(
                op: op,
                count: values.count,
                totalMs: total,
                avgMs: total / Double(values.count),
                p50Ms: percentile(values, 0.5),
                p95Ms: percentile(values, 0.95),
                maxMs: values.last ?? 0,
                bytes: group.map(\.bytes).reduce(0, +)
            ))
        }

        // Single exchanges only. Summary lines (a whole file, the OK wait, the gallery) would crowd them out.
        let exchanges = timed.filter { !["file", "done", "settle"].contains($0.op) && !$0.op.hasSuffix("-total") }
        let slowest = Array(exchanges.sorted { ($0.took ?? 0) > ($1.took ?? 0) }.prefix(12))

        var files: [FileStat] = []
        for file in result.files {
            let mine = lines.filter { $0.file == file.name }
            let partials = mine.filter { $0.op == "partial" && $0.dir == "IN" && $0.took != nil }
            let transfer = partials.compactMap(\.took).reduce(0, +)
            let total = mine.first { $0.op == "file" && $0.took != nil }?.took ?? 0
            let firstBytes = partials.compactMap(\.firstByte)
            let stalls = mine.filter { $0.title == "TCP stall" }.count
            files.append(FileStat(
                name: file.name,
                bytes: file.got,
                state: file.state,
                totalMs: total,
                transferMs: transfer,
                overheadMs: max(0, total - transfer),
                mbPerSecond: transfer > 0 ? Double(partials.map(\.bytes).reduce(0, +)) / 1_048_576 / (transfer / 1000) : 0,
                chunks: partials.count,
                firstByteAvgMs: firstBytes.isEmpty ? 0 : firstBytes.reduce(0, +) / Double(firstBytes.count),
                stalls: stalls
            ))
        }

        // Failed reads count too: the importer keeps the bytes a dead window delivered.
        let copied = lines.filter { $0.op == "partial" && $0.dir != "OUT" && $0.took != nil }
        let copiedBytes = copied.map(\.bytes).reduce(0, +)
        let copiedMs = copied.compactMap(\.took).reduce(0, +)
        let average = copiedMs > 0 ? Double(copiedBytes) / 1_048_576 / (copiedMs / 1000) : 0

        let transfer = transferStat(lines)
        return Report(
            stamp: log.stamp,
            started: log.started,
            mode: mode,
            host: host,
            environment: environment,
            result: result,
            durationMs: duration,
            copiedBytes: copiedBytes,
            averageMBps: average,
            phases: phases,
            slowest: slowest,
            files: files,
            transfer: transfer,
            findings: findings(lines: lines, phases: phases, files: files, result: result, duration: duration, average: average)
                + transferFindings(transfer),
            lines: lines
        )
    }

    static func transferStat(_ lines: [TraceLine]) -> TransferStat? {
        let windows = lines.filter { ($0.op == "partial" || $0.op == "bench") && $0.dir == "IN" && $0.took != nil && $0.bytes > 0 }
        let failed = lines.filter { ($0.op == "partial" || $0.op == "bench") && $0.dir == "ERR" }
        let benches = lines.filter { $0.op == "bench-total" && $0.took != nil }
        guard !windows.isEmpty || !failed.isEmpty || !benches.isEmpty else { return nil }
        let bytes = windows.map(\.bytes).reduce(0, +)
        let inside = windows.compactMap(\.took).reduce(0, +)
        let starts = windows.map { $0.ms - ($0.took ?? 0) }
        let span = (windows.map(\.ms).max() ?? 0) - (starts.min() ?? 0)
        let rates = windows.compactMap { line -> Double? in
            guard let took = line.took, took > 0 else { return nil }
            return Double(line.bytes) / 1_048_576 / (took / 1000)
        }.sorted()
        let firsts = windows.compactMap(\.firstByte).sorted()
        let gaps = windows.compactMap(\.gap).sorted()
        let receives = windows.compactMap(\.receives)
        // 5 s slices, each window's bytes counted where it ended.
        var timeline: [Double] = []
        if let origin = starts.min() {
            let slice = 5000.0
            var buckets = [Int](repeating: 0, count: Int(span / slice) + 1)
            for line in windows { buckets[min(buckets.count - 1, Int((line.ms - origin) / slice))] += line.bytes }
            timeline = buckets.map { Double($0) / 1_048_576 / (slice / 1000) }
        }
        let bench = benches.map { total -> BenchStat in
            let name = total.title.replacingOccurrences(of: "Window ", with: "")
            let mine = windows.filter { $0.op == "bench" && $0.title == "Partial \(name) windows" }.compactMap(\.firstByte).sorted()
            let ms = total.took ?? 0
            return BenchStat(window: name, ok: total.level != "fail", bytes: total.bytes, ms: ms,
                             mbps: ms > 0 ? Double(total.bytes) / 1_048_576 / (ms / 1000) : 0,
                             firstByteP50Ms: percentile(mine, 0.5))
        }
        return TransferStat(
            windows: windows.count,
            bytes: bytes,
            wireMBps: inside > 0 ? Double(bytes) / 1_048_576 / (inside / 1000) : 0,
            effectiveMBps: span > 0 ? Double(bytes) / 1_048_576 / (span / 1000) : 0,
            windowMBpsP10: percentile(rates, 0.1),
            windowMBpsP50: percentile(rates, 0.5),
            windowMBpsP90: percentile(rates, 0.9),
            firstByteP50Ms: percentile(firsts, 0.5),
            firstByteP95Ms: percentile(firsts, 0.95),
            firstByteMaxMs: firsts.last ?? 0,
            gapP50Ms: percentile(gaps, 0.5),
            gapP95Ms: percentile(gaps, 0.95),
            gapMaxMs: gaps.last ?? 0,
            receivesPerWindow: receives.isEmpty ? 0 : Double(receives.reduce(0, +)) / Double(receives.count),
            reconnects: lines.filter { $0.title == "TCP stall" }.count,
            reconnectMs: lines.filter { $0.op == "reconnect-total" }.compactMap(\.took).reduce(0, +),
            failedWindows: failed.count,
            resentBytes: lines.filter { $0.op == "realign" }.map(\.bytes).reduce(0, +),
            resumedBytes: lines.filter { $0.op == "resume" && $0.title.hasPrefix("Resuming") }.map(\.bytes).reduce(0, +),
            timeline: timeline,
            bench: bench
        )
    }

    /// What the transfer numbers say about where the time goes.
    static func transferFindings(_ t: TransferStat?) -> [Finding] {
        guard let t, t.windows > 0 else { return [] }
        var out: [Finding] = []
        if t.gapP95Ms > 500 {
            out.append(Finding(severity: "warn", title: "The radio drops out mid-window",
                               detail: "1 window in 20 went quiet for \(ms(t.gapP95Ms)) or more after its first byte (worst \(ms(t.gapMaxMs))). That is Wi-Fi, not the camera: distance, a wall, 2.4 GHz interference, or Bluetooth sharing the antenna."))
        }
        if t.wireMBps > 0, t.effectiveMBps < t.wireMBps * 0.6 {
            out.append(Finding(severity: "warn", title: String(format: "%.0f%% of the time is between windows", (1 - t.effectiveMBps / t.wireMBps) * 100),
                               detail: String(format: "Windows move %.2f MB/s, the run as a whole %.2f MB/s. Reconnects took %@, the rest is props, ObjectInfo and saving.", t.wireMBps, t.effectiveMBps, ms(t.reconnectMs))))
        }
        if t.windowMBpsP50 > 0, t.windowMBpsP10 < t.windowMBpsP50 * 0.3 {
            out.append(Finding(severity: "info", title: "Uneven speed",
                               detail: String(format: "Median window %.2f MB/s, slowest tenth under %.2f MB/s. The timeline shows when.", t.windowMBpsP50, t.windowMBpsP10)))
        }
        if let best = t.bench.filter(\.ok).max(by: { $0.mbps < $1.mbps }) {
            out.append(Finding(severity: "info", title: "Speed test: \(best.window) windows were fastest",
                               detail: t.bench.map { "\($0.window) " + ($0.ok ? String(format: "%.2f MB/s", $0.mbps) : "failed") }.joined(separator: ", ")))
        }
        return out
    }

    /// Plain rules over the trace. Each one names something that cost time or broke the session.
    static func findings(lines: [TraceLine], phases: [OpStat], files: [FileStat], result: RunResult, duration: Double, average: Double) -> [Finding] {
        var out: [Finding] = []
        func add(_ severity: String, _ title: String, _ detail: String) {
            out.append(Finding(severity: severity, title: title, detail: detail))
        }
        func phase(_ op: String) -> OpStat? { phases.first { $0.op == op } }

        if !result.ok {
            add("error", "Run stopped: \(result.reason)", result.summary)
        }
        for line in lines where line.title == "Timeout" {
            add("error", "Socket timeout at \(ms(line.ms))", line.detail)
        }
        for line in lines where line.title == "TCP waiting" {
            add("error", "No route to the body at \(ms(line.ms))", line.detail)
            break
        }
        let stalls = lines.filter { $0.title == "TCP stall" }.count
        if stalls > 0 {
            let reconnect = phase("reconnect-total")
            let lost = lines.filter { $0.op == "partial" && $0.level == "fail" }.compactMap(\.took).reduce(0, +)
            add("warn", "\(stalls) stall\(stalls == 1 ? "" : "s") and reconnect\(stalls == 1 ? "" : "s")", "\(ms(lost)) lost inside the failed reads, then \(ms(reconnect?.totalMs ?? 0)) to reconnect. Each one repeats init, settle, OpenSession and the import props; the file resumes from the bytes on disk.")
        }
        let initFails = lines.filter { $0.title == "Init Fail" }.count
        if initFails > 0 {
            add("info", "Init Fail \(initFails)×", "The body rejected the first init. Fuji Bridge retried; each retry is a round trip.")
        }
        let usb = lines.contains { $0.title == "USB connected" || $0.title == "USB open failed" }
        if let connect = phase("connect"), connect.maxMs > 1500 {
            if usb {
                add("info", "Camera took \(ms(connect.maxMs)) to open", "ImageCaptureCore indexes the whole card when a camera session starts fresh: after the cable goes in, or after Fuji Bridge quit mid-import. Later runs open in well under a second.")
            } else {
                add("warn", "Slow TCP connect", "Worst connect took \(ms(connect.maxMs)). The device may still be joining the camera Wi-Fi, or iOS asked for Local Network access.")
            }
        }
        if lines.contains(where: { $0.title == "Catalog still loading" }) {
            add("warn", "Copied while ImageCaptureCore was still indexing", "The two share the cable. Expect a third of the usual USB speed until it finishes.")
        }
        if let wait = phase("ok-wait-total"), wait.totalMs > 3000 {
            add("info", "Waited \(ms(wait.totalMs)) for OK", "Time spent on the camera's confirmation screen. Not a transfer cost, but it is the first thing a user feels.")
        }
        if let setup = phase("setup") {
            let gallery = phase("setup-total")?.totalMs ?? setup.totalMs
            if gallery > 1500 {
                add("warn", "Gallery setup took \(ms(gallery))", "Versions, DF01, DF28, extension info, thumb, folders, dates and D620/D621 before the first file. \(setup.count) exchanges, slowest \(ms(setup.maxMs)).")
            }
        }
        if let prep = phase("prep"), prep.count > 0 {
            let perFile = prep.totalMs / Double(max(1, files.filter { $0.state != "skipped" }.count))
            if perFile > 150 {
                add("warn", "Per-file overhead \(ms(perFile))", "GetObjectInfo and ObjectSize around every file: \(prep.count) exchanges, \(ms(prep.totalMs)) in total, p95 \(ms(prep.p95Ms)).")
            }
        }
        if let partial = phase("partial") {
            if average > 0 && average < 1.0 {
                add("warn", String(format: "Slow transfer %.2f MB/s", average), "Partial reads average \(ms(partial.avgMs)) for up to 1 MB. Check 2.4 vs 5 GHz on the camera, distance, and Low Power Mode.")
            }
            let firstBytes = lines.compactMap(\.firstByte)
            if !firstBytes.isEmpty {
                let avg = firstBytes.reduce(0, +) / Double(firstBytes.count)
                let sorted = firstBytes.sorted()
                if avg > 80 {
                    add("warn", "Body is slow to start each chunk", "Average \(ms(avg)) from GetPartialObject to the first byte (p95 \(ms(percentile(sorted, 0.95)))). That is card/camera latency, not Wi-Fi. Bigger windows would amortise it if the body accepts them.")
                }
            }
            if partial.maxMs > max(4 * partial.p50Ms, 1500) {
                add("warn", "One chunk took \(ms(partial.maxMs))", "Median chunk is \(ms(partial.p50Ms)). Look for a Wi-Fi hiccup or the camera writing to the card.")
            }
        }
        if let save = phase("save"), save.maxMs > 500 {
            add("info", "Slow save to disk", "Worst file write took \(ms(save.maxMs)).")
        }
        for file in files where file.chunks > 0 && file.stalls == 0 && file.totalMs > 0 && file.overheadMs / file.totalMs > 0.35 {
            add("info", "\(file.name): \(Int(file.overheadMs / file.totalMs * 100))% overhead", "\(ms(file.overheadMs)) of \(ms(file.totalMs)) went to props and ObjectInfo, not bytes.")
        }
        // Waiting for OK or for ImageCaptureCore's index is expected silence, already reported on its own.
        let waiting = lines.contains { $0.title == "Catalog complete" || $0.title == "Catalog ready" || $0.title == "Catalog still loading" }
        let catalogEnd = lines.first { $0.title.hasPrefix("Catalog") && $0.title != "Catalog so far" }?.ms ?? 0
        let gaps = zip(lines, lines.dropFirst()).filter { before, after in
            after.ms - before.ms > 2000 && !after.op.hasPrefix("ok-wait") && !before.op.hasPrefix("ok-wait")
                && !(waiting && after.ms <= catalogEnd)
        }
        for (before, after) in gaps.prefix(5) {
            add("warn", "Silent for \(ms(after.ms - before.ms))", "Between \"\(before.title)\" at \(ms(before.ms)) and \"\(after.title)\" at \(ms(after.ms)).")
        }
        for line in lines where line.op == "app" && line.level != "info" {
            add("warn", line.title + " at \(ms(line.ms))", line.detail)
        }
        let skipped = result.files.filter { $0.state == "skipped" }
        if !skipped.isEmpty {
            add("info", "\(skipped.count) handle\(skipped.count == 1 ? "" : "s") skipped", skipped.map { "\($0.handle)" }.joined(separator: ", "))
        }
        let already = result.files.filter { $0.state == "already" }
        if !already.isEmpty {
            add("info", "\(already.count) already here", "Same name and size already in the photos folder, not copied again.")
        }
        return out
    }

    static func text(_ report: Report) -> String {
        var out: [String] = []
        let env = report.environment
        out.append("FUJI BRIDGE DIAGNOSTICS \(report.stamp)")
        out.append("")
        out.append("App        \(env.app) (\(env.build)) \(env.bundle)")
        out.append("Platform   \(env.platform)")
        out.append("Device     \(env.device), \(env.system), thermal \(env.thermal)\(env.lowPower ? ", LOW POWER" : "")")
        out.append("Network    \(env.path)")
        out.append("Mode       \(report.mode), body \(report.host):\(Fuji.port)")
        out.append("Started    \(ISO8601DateFormatter().string(from: report.started))")
        out.append("Result     \(report.result.ok ? "OK" : "FAILED") \(report.result.reason): \(report.result.summary)")
        out.append("Duration   \(ms(report.durationMs))")
        out.append(String(format: "Copied     %@ at %.2f MB/s (inside partial reads)", ByteFormat.string(report.copiedBytes), report.averageMBps))
        out.append("")
        out.append("FINDINGS")
        if report.findings.isEmpty { out.append("  nothing stood out") }
        for finding in report.findings {
            out.append("  [\(finding.severity)] \(finding.title)")
            out.append("      \(finding.detail)")
        }
        out.append("")
        out.append("PHASES                 n     total       avg       p50       p95       max      bytes")
        for p in report.phases {
            out.append(
                p.op.padding(toLength: 18, withPad: " ", startingAt: 0)
                    + String(format: "%6d", p.count)
                    + pad(ms(p.totalMs), 10) + pad(ms(p.avgMs), 10) + pad(ms(p.p50Ms), 10)
                    + pad(ms(p.p95Ms), 10) + pad(ms(p.maxMs), 10) + pad(p.bytes > 0 ? ByteFormat.string(p.bytes) : "", 11)
            )
        }
        out.append("")
        out.append("FILES")
        for f in report.files {
            out.append("  \(f.name) \(f.state) \(ByteFormat.string(f.bytes))")
            if f.chunks > 0 {
                out.append(String(format: "      %@ total, %@ moving bytes, %@ overhead, %.2f MB/s, %d chunks, first byte %@ avg, %d stalls",
                                  ms(f.totalMs), ms(f.transferMs), ms(f.overheadMs), f.mbPerSecond, f.chunks, ms(f.firstByteAvgMs), f.stalls))
            }
        }
        out.append("")
        if let t = report.transfer {
            out.append("TRANSFER")
            out.append(String(format: "  %d windows, %@, wire %.2f MB/s, effective %.2f MB/s", t.windows, ByteFormat.string(t.bytes), t.wireMBps, t.effectiveMBps))
            out.append(String(format: "  window MB/s     p10 %.2f  p50 %.2f  p90 %.2f", t.windowMBpsP10, t.windowMBpsP50, t.windowMBpsP90))
            out.append("  first byte      p50 \(ms(t.firstByteP50Ms))  p95 \(ms(t.firstByteP95Ms))  max \(ms(t.firstByteMaxMs))")
            out.append("  silence inside  p50 \(ms(t.gapP50Ms))  p95 \(ms(t.gapP95Ms))  max \(ms(t.gapMaxMs))" + String(format: "  (%.0f receives per window)", t.receivesPerWindow))
            out.append("  reconnects      \(t.reconnects), \(ms(t.reconnectMs)); \(t.failedWindows) windows died; \(ByteFormat.string(t.resentBytes)) asked twice; \(ByteFormat.string(t.resumedBytes)) resumed from disk")
            if !t.timeline.isEmpty {
                out.append("  MB/s per 5 s    " + t.timeline.map { String(format: "%.1f", $0) }.joined(separator: " "))
            }
            for b in t.bench {
                out.append("  speed test \(b.window.padding(toLength: 7, withPad: " ", startingAt: 0)) " + (b.ok ? String(format: "%.2f MB/s", b.mbps) : "failed") + "  \(ByteFormat.string(b.bytes)) in \(ms(b.ms)), first byte p50 \(ms(b.firstByteP50Ms))")
            }
            out.append("")
        }
        out.append("SLOWEST EXCHANGES")
        for line in report.slowest {
            out.append("  \(pad(ms(line.took ?? 0), 9))  @\(ms(line.ms))  [\(line.op)] \(line.title)  \(line.detail)")
        }
        out.append("")
        out.append("TRACE (ms since start, took)")
        for line in report.lines {
            let took = line.took.map { " (" + ms($0) + ")" } ?? ""
            out.append(String(format: "%9.1f ", line.ms) + "\(line.dir.padding(toLength: 4, withPad: " ", startingAt: 0)) [\(line.op)] \(line.title)\(took)  \(line.detail)")
            if !line.hex.isEmpty { out.append("           \(line.hex)") }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Writes the .txt and .json next to the .jsonl. Returns the report files.
    @discardableResult
    static func save(_ report: Report) -> [URL] {
        let dir = folder()
        let txt = dir.appendingPathComponent(report.stamp + ".txt")
        let json = dir.appendingPathComponent(report.stamp + ".json")
        try? text(report).data(using: .utf8)?.write(to: txt, options: .atomic)
        if let data = try? encoder(pretty: true).encode(report) {
            try? data.write(to: json, options: .atomic)
        }
        return [txt, json]
    }

    static func history() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder(), includingPropertiesForKeys: nil)) ?? []
        return urls.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func clear() {
        for url in history() { try? FileManager.default.removeItem(at: url) }
    }

    static func ms(_ value: Double) -> String {
        if value >= 10_000 { return String(format: "%.1f s", value / 1000) }
        if value >= 1000 { return String(format: "%.2f s", value / 1000) }
        if value >= 10 { return String(format: "%.0f ms", value) }
        return String(format: "%.1f ms", value)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? " " + text : String(repeating: " ", count: width - text.count) + text
    }

    private static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * q).rounded())))
        return sorted[index]
    }
}

/// Watches the phone's own path during a run: Wi-Fi joined, lost, or swapped for cellular.
final class PathWatch: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "md.thomas.fujibridge.path")
    private let lock = NSLock()
    private var last = "unknown"

    var current: String {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    func start(_ onChange: @escaping @Sendable (String) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            let text = TCPLink.describe(path)
            guard let self else { return }
            self.lock.lock()
            let changed = text != self.last
            self.last = text
            self.lock.unlock()
            if changed { onChange(text) }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
