import SwiftUI

/// Camera settings backups: the camera's own backup file, fetched over Bluetooth and kept in Files.
@MainActor
@Observable
final class SettingsBackups {
    static let shared = SettingsBackups()

    enum State: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var files: [URL] = []

    static func folder() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Settings Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func refresh() {
        files = ((try? FileManager.default.contentsOfDirectory(at: Self.folder(), includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func backUp(model: BenchModel) async {
        if case .working = state { return }
        // The kept Wi-Fi session holds the Bluetooth link; the backup needs its own.
        model.disconnect()
        state = .working("Connecting over Bluetooth…")
        do {
            let result = try await FujiBluetooth.shared.backupSettings { got, _ in
                Task { @MainActor in SettingsBackups.shared.state = .working("Receiving · \(ByteFormat.string(got))") }
            }
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd HH.mm"
            let camera = model.bluetoothCamera ?? "Camera"
            let ext = (result.name as NSString).pathExtension.isEmpty ? "dat" : (result.name as NSString).pathExtension
            let url = Self.folder().appendingPathComponent("\(camera) \(format.string(from: Date())).\(ext)")
            try result.data.write(to: url, options: .atomic)
            state = .done("Saved \(url.lastPathComponent), \(ByteFormat.string(result.data.count)).")
        } catch {
            state = .failed("\(error)")
        }
        refresh()
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refresh()
    }
}

struct BackupPage: View {
    let model: BenchModel
    private let backups = SettingsBackups.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings backup").font(Ink.serif(30, .medium)).foregroundStyle(Ink.ink)
                    Text("Saves the camera's own settings file (menus, custom settings C1–C7, buttons) over Bluetooth, the way Fujifilm's app does. Backups stay in \(Ink.isMac ? "the app's Documents" : "Files › Fuji Bridge › Settings Backups").")
                        .font(Ink.prose(15)).foregroundStyle(Ink.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await backups.backUp(model: model) }
                        } label: {
                            Label(isWorking ? "Backing up…" : "Back up now", systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(PillStyle(filled: true))
                        .disabled(isWorking || model.busy)
                        if isWorking { ProgressView() }
                    }
                    statusLine
                    Text("The camera must be on and paired with this device. Restoring a backup to the camera will come once backups are confirmed to work on the X100VI.")
                        .font(Ink.side(.detail)).foregroundStyle(Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Backups").font(Ink.side(.header)).foregroundStyle(Ink.ink2)
                    if backups.files.isEmpty {
                        Text("None yet.").font(Ink.side(.detail)).foregroundStyle(Ink.ink2)
                    }
                    ForEach(backups.files, id: \.path) { url in
                        HStack(spacing: 12) {
                            Image(systemName: "doc").foregroundStyle(Ink.ink2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.deletingPathExtension().lastPathComponent).font(Ink.side(.title)).foregroundStyle(Ink.ink)
                                Text(ByteFormat.string(size(url))).font(Ink.side(.detail)).foregroundStyle(Ink.ink2)
                            }
                            Spacer()
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 36, height: 36) }
                                .buttonStyle(.plain).foregroundStyle(Ink.ink)
                            Button(role: .destructive) { backups.delete(url) } label: {
                                Image(systemName: "trash").frame(width: 36, height: 36)
                            }
                            .buttonStyle(.plain).foregroundStyle(Ink.bad)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.rule, lineWidth: 1))
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Ink.paper)
        .onAppear { backups.refresh() }
    }

    private var isWorking: Bool { if case .working = backups.state { return true } else { return false } }

    @ViewBuilder
    private var statusLine: some View {
        switch backups.state {
        case .idle: EmptyView()
        case .working(let text): Text(text).font(Ink.side(.detail)).foregroundStyle(Ink.ink2)
        case .done(let text): Label(text, systemImage: "checkmark.circle.fill").font(Ink.side(.detail)).foregroundStyle(Ink.good)
        case .failed(let text): Label(text, systemImage: "exclamationmark.triangle.fill").font(Ink.side(.detail)).foregroundStyle(Ink.bad)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }
}
