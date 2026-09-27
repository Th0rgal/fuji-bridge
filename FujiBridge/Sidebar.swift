import SwiftUI

/// One import as its diagnostics report tells it. Only the fields the sidebar shows are decoded; the
/// report files also carry the whole trace.
struct ImportRun: Identifiable, Decodable {
    struct Result: Decodable {
        struct File: Decodable { var state: String }
        var ok: Bool
        var reason: String
        var summary: String
        var files: [File]
    }

    var stamp: String
    var started: Date
    var mode: String
    var host: String?
    var result: Result
    var copiedBytes: Int
    var averageMBps: Double
    var id: String { stamp }

    var copied: Int { result.files.filter { $0.state == "full" }.count }
    var already: Int { result.files.filter { $0.state == "already" }.count }
    var over: String { mode.contains("USB") ? "USB" : (mode.contains("Wi-Fi") ? "Wi-Fi" : mode) }

    /// The newest imports, newest first. Browses, full-size looks and the test bench are left out.
    /// How many attempts in a row ended the same way (the sidebar folds them into one line).
    var repeats = 1

    /// "link" and friends, as a person would say it.
    var why: String { Self.why(result.reason) }

    static func why(_ reason: String) -> String {
        switch reason {
        case "link": return "camera not reachable"
        case "ok-timeout": return "OK not pressed on the camera"
        case "stall": return "connection lost"
        case "empty": return "nothing to copy"
        case "aborted": return "stopped by you"
        default: return reason
        }
    }

    enum CodingKeys: String, CodingKey { case stamp, started, mode, host, result, copiedBytes, averageMBps }

    static func recent(limit: Int = 6) -> [ImportRun] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Older reports are named -usb, -wifi or -camera without the purpose; their result tells a browse apart.
        let names = Diagnostics.history().filter { url in
            let name = url.lastPathComponent
            return url.pathExtension == "json" && !name.contains("virtual") && !name.contains("-browse") && !name.contains("-open")
        }
        var runs: [ImportRun] = []
        for url in names.prefix(60) where runs.count < limit {
            guard let data = try? Data(contentsOf: url), let run = try? decoder.decode(ImportRun.self, from: data),
                  run.result.reason != "previewed", !(run.host ?? "").hasPrefix("127.") else { continue }
            // A run of identical failures (a camera out of reach, tried again and again) is one line.
            if let last = runs.last, !last.result.ok, !run.result.ok, last.result.reason == run.result.reason {
                runs[runs.count - 1].repeats += 1
                continue
            }
            runs.append(run)
        }
        return runs
    }
}

/// What is already on this device: how many photos, how much room, the newest one.
struct LibrarySummary: Equatable {
    var count = 0
    var bytes = 0
    var newest: String?
    var newestDate: Date?

    static func read(_ urls: [URL]) -> LibrarySummary {
        var summary = LibrarySummary(count: urls.count)
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            summary.bytes += values?.fileSize ?? 0
        }
        // Newest first already: Fuji names count up.
        if let first = urls.first {
            summary.newest = first.lastPathComponent
            summary.newestDate = (try? first.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        return summary
    }
}

/// The lower half of the sidebar: the library and the last imports, so the column says something
/// useful once the buttons are done.
struct SidebarDetails: View {
    let saved: [URL]
    let reportStamp: String?
    let reveal: () -> Void

    @State private var library = LibrarySummary()
    @State private var runs: [ImportRun] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Library") {
                row(icon: "photo.on.rectangle", title: library.count == 0 ? "No photos yet" : "\(library.count) photo\(library.count == 1 ? "" : "s")",
                    detail: library.count == 0 ? (Ink.isMac ? "Pictures › Fuji Bridge" : "Files › Fuji Bridge") : Self.size(library.bytes))
                if let newest = library.newest {
                    row(icon: "clock", title: newest, detail: library.newestDate.map { "newest · " + Self.when($0) } ?? "newest")
                }
                LinkButton(title: Ink.isMac ? "Show in Finder" : "Open in Files", systemImage: "folder", action: reveal)
                    .padding(.leading, 30)
            }
            section("Recent imports") {
                if runs.isEmpty {
                    Text("Nothing imported from a camera yet.")
                        .font(Ink.side(.detail))
                        .foregroundStyle(Ink.ink2)
                }
                ForEach(runs) { run in
                    if run.result.ok {
                        row(icon: "checkmark.circle", tint: Ink.good,
                            title: run.copied > 0 ? "\(run.copied) new · \(Self.size(run.copiedBytes))" : "Up to date",
                            detail: [Self.when(run.started), run.over, run.copied > 0 ? String(format: "%.0f MB/s", run.averageMBps) : "\(run.already) already here"].joined(separator: " · "))
                    } else {
                        row(icon: "exclamationmark.triangle", tint: Ink.bad,
                            title: run.repeats > 1 ? "\(run.repeats) attempts · \(run.why)" : "Stopped · \(run.why)",
                            detail: "\(run.repeats > 1 ? "last " : "")\(Self.when(run.started)) · \(run.over)")
                    }
                }
            }
        }
        .task(id: "\(saved.count)-\(saved.first?.path ?? "")") {
            let urls = saved
            library = await Task.detached(priority: .utility) { LibrarySummary.read(urls) }.value
        }
        .task(id: reportStamp ?? "") {
            runs = await Task.detached(priority: .utility) { ImportRun.recent() }.value
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Ink.side(.header))
                .foregroundStyle(Ink.ink2)
            content()
        }
    }

    private func row(icon: String, tint: Color = Ink.muted, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: Ink.isMac ? 13 : 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Ink.side(.title))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(Ink.side(.detail))
                    .monospacedDigit()
                    .foregroundStyle(Ink.ink2)
                    .lineLimit(1)
            }
        }
    }

    static func size(_ bytes: Int) -> String {
        bytes >= 1_073_741_824 ? String(format: "%.1f GB", Double(bytes) / 1_073_741_824) : ByteFormat.string(bytes)
    }

    static func when(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "today " + date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "yesterday " + date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}
