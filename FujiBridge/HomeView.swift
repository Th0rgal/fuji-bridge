import SwiftUI
import UIKit

enum GalleryTab: String, CaseIterable, Identifiable {
    case imported = "Imported"
    case camera = "On the camera"
    var id: String { rawValue }
}

/// The app. Wide windows (Mac, iPad) get the controls on the left and the photos filling the rest;
/// a phone gets the controls on top of the same grid. Same views either way.
struct HomeView: View {
    @State private var model = BenchModel()
    @State private var tab: GalleryTab = .imported
    /// Imported files picked in the grid, for Share and Delete. The camera's selection lives in the model.
    @State private var picked: Set<URL> = []
    @State private var pickedAnchor: URL?
    @State private var cameraAnchor: Int?
    @State private var ratios: [URL: CGFloat] = [:]
    @State private var confirmDelete = false
    /// Mac only: the sidebar's Diagnostics row pushes onto the detail column.
    @State private var showDiagnostics = false
    @State private var deleteError: String?
    /// Target row height of the grid. Command-plus and Command-minus, or a pinch.
    @AppStorage("BridgeRowHeight") private var zoom: Double = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        root
        .tint(Ink.ink)
        .overlay { viewerOverlay }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deletePicked() }
        } message: {
            Text(Ink.isMac ? "They go to the Trash. The camera keeps its copy." : "They are removed from Fuji Bridge. The camera keeps its copy.")
        }
        .alert("Could not delete", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.lifecycle("active")
                // Files may have been removed in Finder or Files meanwhile.
                if !model.busy { model.refreshSaved() }
            case .inactive: model.lifecycle("inactive")
            case .background: model.lifecycle("background")
            @unknown default: break
            }
        }
        .onChange(of: model.saved) { _, saved in picked.formIntersection(saved) }
        .onAppear {
            model.refreshSaved()
            if UserDefaults.standard.string(forKey: "BridgeAutoRun") == "browse" || UserDefaults.standard.string(forKey: "BridgeTab") == "camera" { tab = .camera }
            #if DEBUG
            // Store screenshots: -BridgeDemoCamera X100VI shows a paired body without Bluetooth.
            if let name = UserDefaults.standard.string(forKey: "BridgeDemoCamera") {
                model.bluetoothCamera = name
                model.bluetoothPairedHere = true
            }
            if UserDefaults.standard.bool(forKey: "BridgeDemoCard") {
                model.cameraPhotos = DemoCard.photos(from: model.saved)
                model.selection = Set(model.cameraPhotos.filter { !model.importedNames.contains($0.name) }.prefix(4).map(\.handle))
                tab = .camera
            }
            #endif
        }
    }


    /// The Mac gets the system sidebar: a real split view, so the column is translucent over the desktop
    /// like Finder's or Mail's. The phone and the iPad keep one stack with their own layout.
    @ViewBuilder
    private var root: some View {
        if Ink.isMac {
            macRoot
        } else {
            NavigationStack {
                GeometryReader { geo in
                    if geo.size.width >= 760 {
                        HStack(alignment: .top, spacing: 0) {
                            VStack(spacing: 0) {
                                ScrollView {
                                    controls.padding(20)
                                }
                                if Ink.isMac { sidebarFooter }
                            }
                            .frame(width: min(340, max(290, geo.size.width * 0.28)))
                            .background(Ink.paper)
                            Rectangle().fill(Ink.rule).frame(width: 1)
                            galleryScroll(wide: true)
                        }
                    } else {
                        galleryScroll(wide: false)
                    }
                }
                .background(Ink.paper)
                .navigationTitle("Fuji Bridge")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        NavigationLink {
                            diagnostics
                        } label: {
                            Label("Diagnostics", systemImage: diagnosticsIcon)
                        }
                    }
                }
                // The Mac window already says Fuji Bridge in its title bar; a second bar under it only costs photos.
                .toolbar(Ink.isMac ? .hidden : .automatic, for: .navigationBar)
                .background { shortcuts }
                .background { ModifierKeys.Listener().frame(width: 0, height: 0) }
            }
        }
    }

    private var macRoot: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                ScrollView {
                    controls.padding(.horizontal, 18).padding(.top, 2).padding(.bottom, 20)
                }
                .scrollContentBackground(.hidden)
                sidebarFooter
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 310, max: 380)
            .toolbar(.hidden, for: .navigationBar)
        } detail: {
            NavigationStack {
                // The title bar's strip stays out of the grid: under it, macOS blurs on hover and eats clicks.
                // Painting it the paper color keeps it from reading as a band.
                galleryScroll(wide: true)
                    .background(Ink.paper.ignoresSafeArea())
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(isPresented: $showDiagnostics) { diagnostics }
                    .background { shortcuts }
                    .background { ModifierKeys.Listener().frame(width: 0, height: 0) }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            MacToolbar.shared.onTab = { tab = $0 }
            MacToolbar.shared.onAction = { toolbarAction() }
            syncToolbar()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "BridgeShowDiagnostics") { showDiagnostics = true }
            #endif
        }
        .onChange(of: tab) { _, _ in syncToolbar() }
        .onChange(of: showDiagnostics) { _, shown in MacToolbar.shared.setGalleryVisible(!shown) }
        .onChange(of: model.saved.count) { _, _ in syncToolbar() }
        .onChange(of: model.cameraPhotos.count) { _, _ in syncToolbar() }
        .onChange(of: model.selection) { _, _ in syncToolbar() }
    }

    private var diagnostics: some View {
        DiagnosticsView(report: model.report, files: model.reportFiles, model: model)
    }

    private var diagnosticsIcon: String {
        (model.report?.findings.contains { $0.severity != "info" } ?? false) ? "stethoscope.circle.fill" : "stethoscope"
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Ink.rule).frame(height: 1)
            Button { showDiagnostics = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: diagnosticsIcon)
                    Text("Diagnostics")
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.muted)
                }
                .font(Ink.side(.title))
                .foregroundStyle(Ink.ink2)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(InkPress())
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            cameraCard
            if Ink.isMac || UIDevice.current.userInterfaceIdiom == .pad {
                SidebarDetails(saved: model.saved, reportStamp: model.report?.stamp) { model.revealPhotos() }
                    .padding(.top, 6)
            }
        }
    }

    // MARK: Camera card

    /// One card for the camera, whatever it is doing: who it is, what is happening, what can be done.
    /// Idle, pairing, joining, copying and the last result all live in the same frame.
    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader
            if running {
                runBody
            } else {
                idleBody
            }
        }
        .padding(14)
        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.rule, lineWidth: 1))
        .animation(.snappy, value: running)
        .animation(.snappy, value: model.phase)
    }

    private var running: Bool { model.busy && model.mode == .camera }

    private var cardHeader: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: cameraIcon)
                .font(.system(size: Ink.isMac ? 16 : 18, weight: .medium))
                .foregroundStyle(connected ? Ink.ink : Ink.muted)
                .frame(width: 36, height: 36)
                .background(Ink.paper, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(connected ? Ink.good : Ink.muted.opacity(0.45))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Ink.surface, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.usbCamera ?? model.bluetoothCamera ?? "No camera")
                    .font(Ink.side(.name))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                Label(linkLabel, systemImage: linkSymbol)
                    .font(Ink.side(.detail))
                    .foregroundStyle(Ink.ink2)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if running {
                Button { model.stop() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Ink.surface2, in: Circle())
                }
                .buttonStyle(InkPress())
                .foregroundStyle(Ink.ink2)
                .help("Stop")
                .accessibilityLabel("Stop")
            }
        }
    }

    private var linkLabel: String {
        if model.usbCamera != nil { return "USB" }
        if model.bluetoothCamera != nil { return model.bluetoothPairedHere ? "Bluetooth · paired" : "Bluetooth" }
        return model.bluetoothEnabled ? "Listening" : "Wi-Fi · \(model.host)"
    }

    private var linkSymbol: String {
        if model.usbCamera != nil { return "bolt.horizontal" }
        if model.bluetoothCamera != nil || model.bluetoothEnabled { return "dot.radiowaves.left.and.right" }
        return "wifi"
    }

    private var connected: Bool { model.usbCamera != nil || model.bluetoothCamera != nil }

    private var cameraIcon: String {
        if model.usbCamera != nil { return "cable.connector" }
        if model.bluetoothCamera != nil { return "camera" }
        return "camera"
    }

    // MARK: Idle

    @ViewBuilder
    private var idleBody: some View {
        if model.usbCamera == nil && model.bluetoothNeedsPairing {
            CardLine(symbol: "link.badge.plus", tint: Ink.bad, text: "Paired with another device", detail: "Camera: Bluetooth › Pairing registration") {
                SmallPill(title: "Pair", symbol: nil) { model.pairBluetooth() }.disabled(model.busy)
            }
        } else if !connected {
            CardLine(symbol: "hand.point.up.left", tint: Ink.muted, text: "Plug in or switch on", detail: model.bluetoothEnabled ? "Not showing? Turn Bluetooth off on your phone." : nil) {
                if !model.bluetoothEnabled {
                    SmallPill(title: nil, symbol: "antenna.radiowaves.left.and.right") { model.enableBluetooth() }
                        .help("Find the camera over Bluetooth")
                }
            }
        }
        if model.mode == .camera, let summary = model.summary, model.purpose != .browse || model.phase == "Stopped" {
            CardLine(symbol: summaryTone == .bad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                     tint: summaryTone == .bad ? Ink.bad : Ink.good, text: resultTitle, detail: resultDetail ?? summary) {
                Button { model.summary = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.muted)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        actionRow
    }

    /// Import, with its scope folded into the same button, and Browse beside it as an icon.
    private var actionRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Button { model.importFromCamera() } label: {
                    Label(model.selection.isEmpty ? "Import" : "Import \(model.selection.count)", systemImage: "arrow.down.to.line")
                        .font(Ink.side(.title, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if model.selection.isEmpty {
                    Rectangle().fill(Ink.paper.opacity(0.25)).frame(width: 1, height: 18)
                    Menu {
                        Picker("Photos", selection: $model.scope) {
                            ForEach(Scope.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HStack(spacing: 3) {
                            Text(scopeShort).font(Ink.side(.title, .semibold)).monospacedDigit()
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("How much of the card to look at")
                }
            }
            .foregroundStyle(Ink.paper)
            .background(Ink.ink, in: Capsule())
            Button {
                tab = .camera
                model.browse()
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 38, height: 38)
                    .background(Ink.paper, in: Circle())
                    .overlay(Circle().strokeBorder(Ink.rule, lineWidth: 1))
            }
            .buttonStyle(InkPress())
            .foregroundStyle(Ink.ink)
            .help(model.cameraPhotos.isEmpty ? "Browse the camera" : "Browse again")
            .accessibilityLabel("Browse the camera")
        }
        .disabled(model.busy)
        .opacity(model.busy ? 0.4 : 1)
    }

    /// The last run in a few words: "3 new", "Up to date", "Stopped".
    private var resultTitle: String {
        if summaryTone == .bad { return model.purpose == .browse ? "Could not read the card" : "Stopped" }
        let copied = model.files.filter { $0.state == "full" }.count
        if model.purpose == .browse { return "\(model.cameraPhotos.count) on the camera" }
        return copied == 0 ? "Up to date" : "\(copied) new photo\(copied == 1 ? "" : "s")"
    }

    /// Its second line: size and speed, how many were already here, or why it stopped.
    private var resultDetail: String? {
        if summaryTone == .bad {
            guard let reason = model.report?.result.reason else { return nil }
            return ImportRun.why(reason)
        }
        let copied = model.files.filter { $0.state == "full" }
        let already = model.files.filter { $0.state == "already" }.count
        var parts: [String] = []
        if !copied.isEmpty {
            parts.append(SidebarDetails.size(copied.map(\.got).reduce(0, +)))
            if let speed = model.report?.averageMBps, speed > 0 { parts.append(String(format: "%.0f MB/s", speed)) }
        }
        if already > 0 { parts.append("\(already) already here") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var scopeShort: String {
        switch model.scope {
        case .all: return "All"
        default: return "\(model.scope.rawValue)"
        }
    }

    // MARK: Running

    @ViewBuilder
    private var runBody: some View {
        StepRail(steps: runSteps.map(\.symbol), current: runStep)
        CardLine(symbol: nil, tint: Ink.ink, text: runHeadline, detail: runDetail) { EmptyView() }
        if model.purpose == .browse {
            MonoLine(items: ["\(model.cameraPhotos.count) listed"])
        } else if let p = model.progress, p.count > 0 {
            let done = (Double(p.index) + (p.total > 0 ? Double(p.got) / Double(p.total) : 0)) / Double(p.count)
            ProgressView(value: min(max(done, 0), 1)).tint(Ink.ink)
            MonoLine(items: [
                "\(p.index + 1)/\(p.count)",
                p.bytesPerSecond > 0 ? String(format: "%.1f MB/s", p.bytesPerSecond / 1_048_576) : nil,
                remaining(done).map { "\($0) left" },
            ].compactMap { $0 })
        }
        if model.joinByHand, let wifi = model.cameraWifi {
            JoinRow(wifi: wifi)
        }
    }

    private var runHeadline: String {
        switch model.purpose {
        case .browse where runStep == runSteps.count - 1: return "Reading the card"
        case .open: return "Fetching full size"
        default: return runSteps[min(runStep, runSteps.count - 1)].title
        }
    }

    /// One short line under the headline, only when it tells the user something to do or wait for.
    private var runDetail: String? {
        let phase = model.phase
        if phase.hasPrefix("Confirm") { return "Confirm the same code on both" }
        if phase.hasPrefix("Press OK") { return "Press OK on the camera" }
        if phase.hasPrefix("Waiting for the camera's pairing") { return "Open Pairing registration on the camera" }
        if phase.hasPrefix("Looking") { return "Switch the camera on" }
        if let p = model.progress, p.count > 0, model.purpose != .browse { return p.name }
        return nil
    }

    /// The stages of this run: an icon for the rail, a word for the headline.
    private var runSteps: [(symbol: String, title: String, key: String)] {
        let card = (symbol: "sdcard", title: "Opening the card", key: "card")
        let copy = model.purpose == .browse
            ? (symbol: "square.grid.2x2", title: "Listing photos", key: "copy")
            : (symbol: "photo.on.rectangle", title: "Copying", key: "copy")
        if model.runTransport == .usb {
            return [(symbol: "cable.connector", title: "Opening the camera", key: "open"), card, copy]
        }
        if model.bluetoothEnabled {
            return [(symbol: "dot.radiowaves.left.and.right", title: "Finding the camera", key: "find"),
                    (symbol: "wifi", title: "Waking its Wi-Fi", key: "wake"),
                    (symbol: "network", title: "Joining its network", key: "join"), card, copy]
        }
        return [(symbol: "wifi", title: "Reaching the camera", key: "reach"), card, copy]
    }

    /// Which stage the model's phase belongs to.
    private var runStep: Int {
        let phase = model.phase
        func stage(_ key: String) -> Int { runSteps.firstIndex { $0.key == key } ?? 0 }
        if phase.hasPrefix("Copying") || phase == "Reconnecting" { return stage("copy") }
        if phase == "Reading the card" || phase.hasPrefix("Press OK") { return stage("card") }
        if model.runTransport == .usb { return stage("open") }
        if model.bluetoothEnabled {
            if phase.hasPrefix("Waking") { return stage("wake") }
            if phase.hasPrefix("Join") || phase == "Connecting" { return stage("join") }
            return stage("find")
        }
        return stage("reach")
    }

    private var summaryTone: NoticeTone {
        switch model.phase {
        case "Stopped": return .bad
        case "Copied": return .good
        default: return .info
        }
    }

    private var summaryTitle: String {
        switch model.phase {
        case "Stopped": return model.purpose == .browse ? "Could not read the card" : "The import stopped"
        case "Copied": return "Done"
        default: return model.phase
        }
    }

    private func remaining(_ done: Double) -> String? {
        guard let started = model.runStarted, done > 0.02 else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        let seconds = Int(elapsed / done - elapsed)
        return seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
    }

    // MARK: Gallery

    private func galleryScroll(wide: Bool) -> some View {
        let pad: CGFloat = wide ? 20 : 12
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                if !wide {
                    controls
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 18)
                }
                Section {
                    gallery(rowHeight: rowHeight(wide: wide))
                        .padding(.horizontal, pad)
                        .padding(.bottom, 24)
                } header: {
                    // On the Mac the switch and the action live in the window's toolbar.
                    if !Ink.isMac {
                    galleryHeader
                        .padding(.horizontal, pad)
                        .padding(.vertical, 10)
                        .background(Ink.paper)
                        .overlay(alignment: .bottom) { Rectangle().fill(Ink.rule.opacity(0.6)).frame(height: 0.5) }
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .simultaneousGesture(
            MagnifyGesture().onEnded { value in
                zoom = min(max((zoom == 0 ? rowHeight(wide: wide) : zoom) * value.magnification, 80), 420)
            }
        )
        .safeAreaInset(edge: .bottom) { selectionBar }
    }

    private func rowHeight(wide: Bool) -> CGFloat {
        zoom > 0 ? zoom : (wide ? 190 : 118)
    }

    private var galleryHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("Show", selection: $tab) {
                Text("Imported · \(model.saved.count)").tag(GalleryTab.imported)
                Text(model.cameraPhotos.isEmpty ? "On the camera" : "On the camera · \(model.cameraPhotos.count)").tag(GalleryTab.camera)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)
            Spacer(minLength: 0)
            galleryAction
        }
    }

    @ViewBuilder
    private func gallery(rowHeight: CGFloat) -> some View {
        switch tab {
        case .imported:
            if model.saved.isEmpty {
                empty("Nothing imported yet", "Photos you import land in \(Ink.isMac ? "Pictures › Fuji Bridge" : "Files › Fuji Bridge"), newest first.", icon: "photo.on.rectangle.angled",
                      action: ("Import new photos", "arrow.down.to.line", { model.importFromCamera() }))
            } else {
                JustifiedGrid(items: model.saved.map(LocalItem.init), ratio: { ratios[$0.url] ?? ImageRatio.standard }, rowHeight: rowHeight) { item, _ in
                    let url = item.url
                    LocalTile(url: url, selected: picked.contains(url))
                        .selectable(open: { openViewer(.local(url)) }) { kind in clickImported(url, kind) }
                        .contextMenu { importedMenu(url) }
                }
                .task(id: model.saved) {
                    let missing = model.saved.filter { ratios[$0] == nil }
                    guard !missing.isEmpty else { return }
                    let read = await ImageRatio.load(missing)
                    ratios.merge(read) { _, new in new }
                }
            }
        case .camera:
            if model.cameraPhotos.isEmpty {
                if model.busy && model.purpose == .browse {
                    empty("Reading the card", "Thumbnails appear here as the camera sends them.", icon: "ellipsis")
                } else {
                    empty("See the card before importing", "Browse the camera to look at its photos and pick the ones to copy. Fuji Bridge lists the \(model.scope == .all ? "whole card" : model.scope.label.lowercased()), as set on the left.", icon: "camera",
                          action: ("Browse the camera", "square.grid.2x2", { model.browse() }))
                }
            } else {
                JustifiedGrid(items: model.cameraPhotos, ratio: CameraThumb.ratio, rowHeight: rowHeight) { photo, _ in
                    CameraTile(photo: photo, selected: model.selection.contains(photo.handle), imported: model.importedNames.contains(photo.name))
                        .selectable(open: { openViewer(.camera(photo)) }) { kind in clickCamera(photo, kind) }
                        .contextMenu { cameraMenu(photo) }
                }
            }
        }
    }

    @ViewBuilder
    private var galleryAction: some View {
        switch tab {
        case .imported:
            LinkButton(title: Ink.isMac ? "Show in Finder" : "Files", systemImage: "folder") { model.revealPhotos() }
        case .camera:
            if !model.cameraPhotos.isEmpty && model.selection.isEmpty {
                let fresh = freshHandles
                LinkButton(title: "Select new · \(fresh.count)") { model.selection = Set(fresh) }
                    .disabled(model.busy || fresh.isEmpty)
            }
        }
    }

    /// What the toolbar's right button says and does, mirroring `galleryAction`.
    private var toolbarActionTitle: String? {
        switch tab {
        case .imported: return "Show in Finder"
        case .camera:
            guard !model.cameraPhotos.isEmpty, model.selection.isEmpty, !freshHandles.isEmpty, !model.busy else { return nil }
            return "Select new · \(freshHandles.count)"
        }
    }

    private func toolbarAction() {
        switch tab {
        case .imported: model.revealPhotos()
        case .camera: model.selection = Set(freshHandles)
        }
    }

    private func syncToolbar() {
        MacToolbar.shared.update(tab: tab, imported: model.saved.count, camera: model.cameraPhotos.count, action: toolbarActionTitle)
    }

    private var freshHandles: [Int] {
        model.cameraPhotos.filter { !model.importedNames.contains($0.name) }.map(\.handle)
    }

    /// Nothing to show: centered in the visible area, one sentence of why, and the button that fixes it.
    private func empty(_ title: String, _ detail: String, icon: String, action: (String, String, () -> Void)? = nil) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Ink.muted)
                .frame(width: 68, height: 68)
                .background(Ink.surface, in: Circle())
                .padding(.bottom, 6)
            Text(title)
                .font(Ink.serif(26, .medium))
                .foregroundStyle(Ink.ink)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(Ink.prose(15))
                .foregroundStyle(Ink.ink2)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
            if let (label, symbol, run) = action {
                Button(action: run) {
                    Label(label, systemImage: symbol)
                        .font(Ink.prose(14, .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .foregroundStyle(Ink.paper)
                        .background(Ink.ink, in: Capsule())
                }
                .buttonStyle(InkPress())
                .disabled(model.busy)
                .opacity(model.busy ? 0.4 : 1)
                .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        // Fill what the scroll view shows, so the message sits in the middle rather than at the top.
        .containerRelativeFrame(.vertical, alignment: .center) { height, _ in max(height - 40, 300) }
    }

    // MARK: Selection

    /// Phone, nothing picked yet: a tap looks at the photo, like Photos. Otherwise a tap picks.
    private func clickImported(_ url: URL, _ kind: SelectionClick.Kind) {
        if kind == .plain && !Ink.isMac && picked.isEmpty {
            openViewer(.local(url))
            return
        }
        SelectionClick.apply(kind, id: url, order: model.saved, selection: &picked, anchor: &pickedAnchor, plainToggles: !Ink.isMac)
    }

    private func clickCamera(_ photo: CardPhoto, _ kind: SelectionClick.Kind) {
        SelectionClick.apply(kind, id: photo.handle, order: model.cameraPhotos.map(\.handle), selection: &model.selection, anchor: &cameraAnchor, plainToggles: !Ink.isMac)
    }

    @ViewBuilder
    private func importedMenu(_ url: URL) -> some View {
        let targets = picked.contains(url) ? Array(picked) : [url]
        Button("Open", systemImage: "eye") { openViewer(.local(url)) }
        if !picked.contains(url) {
            Button("Select", systemImage: "checkmark.circle") { picked.insert(url); pickedAnchor = url }
        }
        ShareLink(items: targets) {
            Label(targets.count > 1 ? "Share \(targets.count) Photos" : "Share", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(targets.count > 1 ? "Delete \(targets.count) Photos" : "Delete", systemImage: "trash", role: .destructive) {
            picked = Set(targets)
            confirmDelete = true
        }
    }

    @ViewBuilder
    private func cameraMenu(_ photo: CardPhoto) -> some View {
        let on = model.selection.contains(photo.handle)
        Button("View", systemImage: "arrow.up.left.and.arrow.down.right") { openViewer(.camera(photo)) }
        Button(on ? "Deselect" : "Select", systemImage: on ? "circle" : "checkmark.circle") { clickCamera(photo, .command) }
        Button(on && model.selection.count > 1 ? "Import \(model.selection.count) Photos" : "Import", systemImage: "arrow.down.to.line") {
            if !on { model.selection = [photo.handle] }
            model.importFromCamera()
        }
        .disabled(model.busy)
    }

    /// Floats over the grid while something is picked: what can be done with it, and a way out.
    @ViewBuilder
    private var selectionBar: some View {
        let count = tab == .imported ? picked.count : model.selection.count
        if count > 0 {
            HStack(spacing: 14) {
                Text("\(count) selected")
                    .font(Ink.mono(13, .medium))
                    .foregroundStyle(Ink.ink)
                    .monospacedDigit()
                Spacer(minLength: 4)
                if tab == .imported {
                    ShareLink(items: Array(picked)) {
                        Label("Share", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                    }
                    .font(.system(size: 16, weight: .medium))
                    .help("Share")
                    Button { confirmDelete = true } label: {
                        Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Ink.bad)
                    .help("Delete")
                } else {
                    Button { model.importFromCamera() } label: {
                        Label("Import", systemImage: "arrow.down.to.line")
                            .font(Ink.prose(14, .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(Ink.paper)
                            .background(Ink.ink, in: Capsule())
                    }
                    .disabled(model.busy)
                }
                Button { clearSelection() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Ink.surface2, in: Circle())
                }
                .foregroundStyle(Ink.ink2)
                .help("Clear the selection (Esc)")
                .accessibilityLabel("Clear selection")
            }
            .buttonStyle(InkPress())
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: 440)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Ink.rule, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Viewer

    private var viewerItems: [ViewerItem] {
        (model.viewer?.tab ?? tab) == .imported ? model.saved.map(ViewerItem.local) : model.cameraPhotos.map(ViewerItem.camera)
    }

    /// The photo on screen in the viewer, if it is open.
    private var shownItem: ViewerItem? {
        guard let viewer = model.viewer else { return nil }
        return viewerItems.first { $0.id == viewer.id }
    }

    @ViewBuilder
    private var viewerOverlay: some View {
        if let viewer = model.viewer {
            let items = viewerItems
            if let index = items.firstIndex(where: { $0.id == viewer.id }) {
                PhotoViewer(
                    items: items,
                    index: index,
                    model: model,
                    selected: isSelected(items[index]),
                    move: moveViewer,
                    toggle: { toggleSelected(items[index]) },
                    close: closeViewer
                )
                .transition(.opacity)
            }
        }
    }

    private func openViewer(_ item: ViewerItem) {
        withAnimation(.easeOut(duration: 0.15)) { model.viewer = Viewer(tab: tab, id: item.id) }
    }

    private func closeViewer() {
        withAnimation(.easeOut(duration: 0.15)) { model.viewer = nil }
    }

    /// Space: close the viewer, or open it on the one photo picked in the grid.
    private func toggleViewer() {
        if model.viewer != nil { closeViewer(); return }
        if tab == .imported, picked.count == 1, let url = picked.first {
            openViewer(.local(url))
        } else if tab == .camera, model.selection.count == 1, let photo = model.cameraPhotos.first(where: { model.selection.contains($0.handle) }) {
            openViewer(.camera(photo))
        } else if let first = viewerItems.first {
            openViewer(first)
        }
    }

    private func moveViewer(_ delta: Int) {
        let items = viewerItems
        guard let viewer = model.viewer, let index = items.firstIndex(where: { $0.id == viewer.id }) else { return }
        let next = min(max(index + delta, 0), items.count - 1)
        guard next != index else { return }
        model.viewer?.id = items[next].id
    }

    /// Arrow keys in the grid move a single selection, so Space then opens the photo it lands on.
    private func moveSelection(_ delta: Int) {
        if tab == .imported {
            let order = model.saved
            guard !order.isEmpty else { return }
            let current = pickedAnchor.flatMap { order.firstIndex(of: $0) } ?? (delta > 0 ? -1 : order.count)
            let next = order[min(max(current + delta, 0), order.count - 1)]
            picked = [next]
            pickedAnchor = next
        } else {
            let order = model.cameraPhotos.map(\.handle)
            guard !order.isEmpty else { return }
            let current = cameraAnchor.flatMap { order.firstIndex(of: $0) } ?? (delta > 0 ? -1 : order.count)
            let next = order[min(max(current + delta, 0), order.count - 1)]
            model.selection = [next]
            cameraAnchor = next
        }
    }

    private func isSelected(_ item: ViewerItem) -> Bool {
        switch item {
        case .local(let url): return picked.contains(url)
        case .camera(let photo): return model.selection.contains(photo.handle)
        }
    }

    private func toggleSelected(_ item: ViewerItem) {
        switch item {
        case .local(let url):
            if picked.contains(url) { picked.remove(url) } else { picked.insert(url); pickedAnchor = url }
        case .camera(let photo):
            if model.selection.contains(photo.handle) { model.selection.remove(photo.handle) } else { model.selection.insert(photo.handle); cameraAnchor = photo.handle }
        }
    }

    private func clearSelection() {
        if tab == .imported { picked = [] } else { model.selection = [] }
    }

    private func selectAll() {
        if tab == .imported { picked = Set(model.saved) } else { model.selection = Set(model.cameraPhotos.map(\.handle)) }
    }

    /// Keyboard, for a Mac or an iPad with one: Select All, Escape, Delete, Space to look, zoom.
    private var shortcuts: some View {
        Group {
            Button("Select All") { selectAll() }.keyboardShortcut("a", modifiers: .command)
            Button("Clear Selection") { model.viewer != nil ? closeViewer() : clearSelection() }.keyboardShortcut(.escape, modifiers: [])
            Button("Previous") { model.viewer != nil ? moveViewer(-1) : moveSelection(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next") { model.viewer != nil ? moveViewer(1) : moveSelection(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("Select Shown") { if let item = shownItem { toggleSelected(item) } }.keyboardShortcut(.return, modifiers: [])
            Button("Full Size") {
                if case .camera(let photo) = shownItem { model.fetchFullSize(photo) }
            }
            .keyboardShortcut("f", modifiers: [])
            Button("Delete") { if tab == .imported && !picked.isEmpty { confirmDelete = true } }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Quick Look") { toggleViewer() }
            .keyboardShortcut(.space, modifiers: [])
            Button("Zoom In") { zoom = min((zoom == 0 ? rowHeight(wide: true) : zoom) * 1.25, 420) }.keyboardShortcut("+", modifiers: .command)
            Button("Zoom In") { zoom = min((zoom == 0 ? rowHeight(wide: true) : zoom) * 1.25, 420) }.keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { zoom = max((zoom == 0 ? rowHeight(wide: true) : zoom) / 1.25, 80) }.keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { zoom = 0 }.keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Delete

    private var deleteTitle: String {
        picked.count == 1 ? "Delete \(picked.first?.lastPathComponent ?? "this photo")?" : "Delete \(picked.count) photos?"
    }

    private func deletePicked() {
        var failed: [String] = []
        for url in picked {
            do {
                if Ink.isMac, (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { continue }
                try FileManager.default.removeItem(at: url)
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        picked = []
        model.refreshSaved()
        if !failed.isEmpty {
            deleteError = "\(failed.sorted().joined(separator: ", ")) could not be removed. Check the folder's permissions and try again."
        }
    }
}

/// A file for the grid, which wants an Identifiable.
private struct LocalItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The bench the app started as: an in-process body with switchable faults, the XApp replay, the trace.
struct LabView: View {
    @Bindable var model: BenchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("A simulated camera built into Fuji Bridge, for testing the protocol. It is not your camera, and nothing it imports is saved. Turn faults on, then import with Fuji Bridge or replay XApp and compare.")
                    .font(Ink.prose(15))
                    .foregroundStyle(Ink.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if model.mode == .virtual {
                    Stat(label: "Status", value: model.phase, tone: model.phase == "Stopped" ? Ink.bad : (model.phase == "Copied" ? Ink.good : Ink.ink))
                    if let summary = model.summary {
                        Text(summary)
                            .font(Ink.prose(15))
                            .foregroundStyle(model.phase == "Stopped" ? Ink.bad : Ink.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                actions
                Hairline()
                faults
                Hairline()
                card
                if !model.compare.isEmpty {
                    Hairline()
                    compare
                }
                Hairline()
                Tag("Wi-Fi body")
                HStack(alignment: .firstTextBaseline) {
                    Text("Address")
                        .font(Ink.mono(13))
                        .foregroundStyle(Ink.ink2)
                    Spacer(minLength: 12)
                    TextField(Fuji.cameraHost, text: $model.host)
                        .font(Ink.mono(15, .medium))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.busy)
                }
                QuietButton(title: "Import over Wi-Fi") { model.importFromCamera(over: .wifi) }
                    .disabled(model.busy)
                Hairline()
                NavigationLink {
                    TraceView(lines: model.lines)
                } label: {
                    Stat(label: "Trace", value: "\(model.lines.count)")
                }
                .buttonStyle(.plain)
                NavigationLink {
                    NotesView()
                } label: {
                    Stat(label: "Protocol", value: "55740")
                }
                .buttonStyle(.plain)
            }
            .padding(22)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Ink.paper)
        .navigationTitle("Test bench")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if model.waiting {
                QuietButton(title: "OK on the virtual body", filled: true) { model.pressOK() }
            }
            QuietButton(title: "Import with Fuji Bridge", filled: true) { model.start(.bridge, mode: .virtual) }
                .disabled(model.busy || model.selected.isEmpty)
            QuietButton(title: "Replay XApp") { model.start(.xapp, mode: .virtual) }
                .disabled(model.busy || model.selected.isEmpty)
            QuietButton(title: model.phase == "Comparing" ? "Comparing..." : "Compare the five stalls") { model.runCompare() }
                .disabled(model.busy || model.selected.isEmpty)
            if model.busy {
                Button("Stop") { model.stop() }
                    .font(Ink.mono(13))
                    .foregroundStyle(Ink.muted)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private var faults: some View {
        VStack(alignment: .leading, spacing: 4) {
            Tag("Faults")
            fault("First init fails", model.faults.flakyHandshake) { model.faults.flakyHandshake.toggle() }
            fault("Body waits for OK", model.faults.requireOk) { model.faults.requireOk.toggle() }
            fault("Wi-Fi dies mid-file", model.faults.stallChunk) { model.faults.stallChunk.toggle() }
            fault("Size stuck at 100 KB", model.faults.lieAboutSize) { model.faults.lieAboutSize.toggle() }
            fault("Skip the 50 ms settle", model.faults.impatientOpen) { model.faults.impatientOpen.toggle() }
        }
    }

    private func fault(_ label: String, _ on: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Stat(label: label, value: on ? "on" : "off", tone: on ? Ink.bad : Ink.muted)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            Tag("Card")
            ForEach(Catalog.roll) { frame in
                let on = model.selected.contains(frame.handle)
                let file = model.mode == .virtual ? model.files.first { $0.handle == frame.handle } : nil
                Button {
                    if model.selected.contains(frame.handle) {
                        model.selected.remove(frame.handle)
                    } else {
                        model.selected.insert(frame.handle)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Stat(
                            label: frame.name,
                            value: file.map { caption($0) } ?? (on ? "selected" : "left"),
                            tone: file?.state == "full" ? Ink.good : (file?.state == "partial" || file?.state == "lost" ? Ink.bad : Ink.ink)
                        )
                        Text("\(frame.recipe) · \(ByteFormat.string(frame.bytes))")
                            .font(Ink.mono(12))
                            .foregroundStyle(Ink.muted)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
            }
        }
    }

    private var compare: some View {
        VStack(alignment: .leading, spacing: 12) {
            Tag("Same card")
            ForEach(model.compare) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.fault)
                        .font(Ink.serif(18))
                        .foregroundStyle(Ink.ink)
                    Text("XApp · \(row.xappOk ? "keeps going" : "stops")")
                        .font(Ink.mono(12))
                        .foregroundStyle(row.xappOk ? Ink.good : Ink.bad)
                    Text(row.xapp)
                        .font(Ink.prose(14))
                        .foregroundStyle(Ink.ink2)
                    Text("Fuji Bridge · \(row.bridgeOk ? "keeps going" : "stops")")
                        .font(Ink.mono(12))
                        .foregroundStyle(row.bridgeOk ? Ink.good : Ink.bad)
                    Text(row.bridge)
                        .font(Ink.prose(14))
                        .foregroundStyle(Ink.ink2)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func caption(_ file: FileResult) -> String {
        switch file.state {
        case "full": return "copied"
        case "partial": return "short"
        case "lost": return "discarded"
        case "already": return "already here"
        default: return file.state
        }
    }
}

struct TraceView: View {
    let lines: [TraceLine]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if lines.isEmpty {
                    Text("Run an import. Containers land here, in order.")
                        .font(Ink.prose(15))
                        .foregroundStyle(Ink.ink2)
                        .padding(22)
                }
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(line.dir)
                                .frame(width: 28, alignment: .leading)
                            Text(String(format: "%.0f", line.ms))
                                .frame(width: 52, alignment: .leading)
                            Text(line.title)
                            Spacer(minLength: 4)
                            if let took = line.took {
                                Text(Diagnostics.ms(took))
                                    .foregroundStyle(took > 1000 ? Ink.bad : Ink.muted)
                            }
                        }
                        .font(Ink.mono(12, .medium))
                        .foregroundStyle(line.level == "fail" ? Ink.bad : Ink.ink)
                        if !line.detail.isEmpty {
                            Text(line.detail)
                                .font(Ink.mono(12))
                                .foregroundStyle(Ink.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !line.hex.isEmpty {
                            Text(line.hex)
                                .font(Ink.mono(11))
                                .foregroundStyle(Ink.muted)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    Hairline()
                        .padding(.horizontal, 22)
                }
            }
        }
        .background(Ink.paper)
        .navigationTitle("Trace")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NotesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("The body speaks Fuji PTP on TCP 55740: an 82-byte init, then USB-style containers. Not ISO PTP/IP.")
                    .font(Ink.prose(16))
                    .foregroundStyle(Ink.ink2)
                note("1", "Init", "Length 0x52, type 1, version 0x8f53e4f2, then the GUID, then the name in UTF-16. The first try often comes back Init Fail. Fuji Bridge sends it again.")
                note("2", "Settle, then OpenSession", "Wait 50 ms. Transaction id starts at 1, not 0.")
                note("3", "0xD212", "CameraState 0xDF00 stays 0 until OK is pressed on the body.")
                note("4", "DF01 = 20", "Remote image view, the XApp gallery dialect. Classic playback writes 2.")
                note("5", "D227", "Until this is 1, ObjectInfo reports about 100 KB and a client that trusts it writes a short JPEG.")
                note("6", "0x101B", "GetPartialObject, at most 1 MB. If the socket dies, keep the offset and ask again. The body usually does not ask for OK a second time.")
                Text("The sequence follows the published libfuji client, not a decompile of XApp. This phone cannot prove what today's iOS XApp binary does. It can show where a session that behaves like that client gives up, and it can talk to the camera when you are on its Wi-Fi.")
                    .font(Ink.prose(15))
                    .foregroundStyle(Ink.muted)
            }
            .padding(22)
        }
        .background(Ink.paper)
        .navigationTitle("Protocol")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func note(_ index: String, _ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(index)
                .font(Ink.mono(11, .medium))
                .tracking(1.4)
                .foregroundStyle(Ink.muted)
            Text(title)
                .font(Ink.serif(20))
                .foregroundStyle(Ink.ink)
            Text(body)
                .font(Ink.prose(15))
                .foregroundStyle(Ink.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

struct DiagnosticsView: View {
    let report: Report?
    let files: [URL]
    var model: BenchModel? = nil
    @State private var history: [URL] = Diagnostics.history()
    /// The report on screen: the last run, or one picked in the history.
    @State private var shown: Report?
    @State private var shownFiles: [URL] = []
    @State private var shownURL: URL?
    /// Decoded once per visit, so each history row can say how its run ended.
    @State private var summaries: [String: Report] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let current = shown ?? report {
                    summary(current, files: shown == nil ? files : shownFiles)
                    tiles(current)
                    findings(current)
                    phases(current)
                    if !current.files.isEmpty { fileList(current) }
                } else {
                    placeholder
                }
                historyList
                footer
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Ink.paper)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            history = Diagnostics.history()
            summaries = Dictionary(uniqueKeysWithValues: history.filter { $0.pathExtension == "txt" }.prefix(30).compactMap { url in Self.load(url).map { (url.path, $0) } })
            if shown == nil && report == nil, let latest = history.first(where: { $0.pathExtension == "txt" }) { open(latest, animated: false) }
        }
    }

    // MARK: Summary

    private func summary(_ report: Report, files: [URL]) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: report.result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(report.result.ok ? Ink.good : Ink.bad)
                .frame(width: 48, height: 48)
                .background((report.result.ok ? Ink.good : Ink.bad).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(headline(report))
                    .font(Ink.side(.name))
                    .foregroundStyle(Ink.ink)
                Label(subline(report), systemImage: report.mode.contains("USB") ? "cable.connector" : (report.mode.contains("Wi-Fi") ? "wifi" : "testtube.2"))
                    .font(Ink.side(.detail))
                    .foregroundStyle(Ink.ink2)
            }
            Spacer(minLength: 8)
            if !files.isEmpty {
                ShareLink(items: files) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(Ink.side(.title, .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .foregroundStyle(Ink.paper)
                        .background(Ink.ink, in: Capsule())
                }
                .buttonStyle(InkPress())
                .help("Share the report, its JSON and the trace")
            }
        }
    }

    private func headline(_ report: Report) -> String {
        if !report.result.ok { return "Stopped · \(ImportRun.why(report.result.reason))" }
        let copied = report.result.files.filter { $0.state == "full" }.count
        switch report.result.reason {
        case "previewed": return "Card listed"
        default: return copied == 0 ? "Up to date" : "\(copied) new photo\(copied == 1 ? "" : "s")"
        }
    }

    private func subline(_ report: Report) -> String {
        [SidebarDetails.when(report.started), report.mode, report.environment.platform].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func tiles(_ report: Report) -> some View {
        let columns = [GridItem(.adaptive(minimum: 140), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            tile("clock", Diagnostics.ms(report.durationMs), "Duration")
            tile("arrow.down.to.line", SidebarDetails.size(report.copiedBytes), "Copied")
            tile("speedometer", report.averageMBps > 0 ? String(format: "%.1f MB/s", report.averageMBps) : "–", "Speed")
            tile("photo.on.rectangle", "\(report.result.files.filter { $0.state == "full" }.count) / \(report.result.files.count)", "Files")
        }
    }

    private func tile(_ symbol: String, _ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ink.muted)
            Text(value)
                .font(.system(size: Ink.isMac ? 17 : 20, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Ink.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(Ink.side(.detail))
                .foregroundStyle(Ink.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.rule, lineWidth: 1))
    }

    // MARK: Findings

    private func findings(_ report: Report) -> some View {
        // Same title twice (Stop pressed at 2.9 s and at 4.4 s) reads as one finding with a count.
        var grouped: [(finding: Finding, count: Int)] = []
        for finding in report.findings {
            let key = finding.title.replacingOccurrences(of: #" at [0-9.]+ m?s$"#, with: "", options: .regularExpression)
            if let i = grouped.firstIndex(where: { $0.finding.title.replacingOccurrences(of: #" at [0-9.]+ m?s$"#, with: "", options: .regularExpression) == key }) {
                grouped[i].count += 1
            } else {
                grouped.append((finding, 1))
            }
        }
        return section("Findings", symbol: "stethoscope") {
            if grouped.isEmpty {
                row(symbol: "checkmark.circle", tint: Ink.good, title: "Nothing stood out", detail: nil)
            }
            ForEach(Array(grouped.enumerated()), id: \.offset) { _, item in
                row(symbol: icon(item.finding.severity), tint: tint(item.finding.severity),
                    title: item.finding.title.hasPrefix("Run stopped: ")
                        ? "Run stopped · \(ImportRun.why(String(item.finding.title.dropFirst("Run stopped: ".count))))"
                        : item.count > 1 ? "\(item.finding.title.replacingOccurrences(of: #" at [0-9.]+ m?s$"#, with: "", options: .regularExpression)) ×\(item.count)" : item.finding.title,
                    detail: item.finding.detail)
            }
        }
    }

    private func icon(_ severity: String) -> String {
        switch severity {
        case "error": return "xmark.octagon.fill"
        case "warn": return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    private func tint(_ severity: String) -> Color {
        switch severity {
        case "error", "warn": return Ink.bad
        default: return Ink.muted
        }
    }

    // MARK: Phases

    private func phases(_ report: Report) -> some View {
        // "-total" rows sum others up; leave them out of the bars so the bars compare like with like.
        let rows = report.phases.filter { !$0.op.hasSuffix("-total") && $0.op != "done" && $0.op != "file" }
        let longest = max(rows.map(\.totalMs).max() ?? 1, 1)
        return section("Time spent", symbol: "chart.bar.xaxis") {
            ForEach(rows, id: \.op) { phase in
                HStack(spacing: 10) {
                    Text(Self.phaseName(phase.op))
                        .font(Ink.side(.title))
                        .foregroundStyle(Ink.ink)
                        .frame(width: 120, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Ink.ink.opacity(0.75))
                            .frame(width: max(3, geo.size.width * phase.totalMs / longest))
                    }
                    .frame(height: 8)
                    Text(Diagnostics.ms(phase.totalMs))
                        .font(Ink.side(.detail))
                        .monospacedDigit()
                        .foregroundStyle(Ink.ink2)
                        .frame(width: 70, alignment: .trailing)
                    Text("×\(phase.count)")
                        .font(Ink.side(.detail))
                        .monospacedDigit()
                        .foregroundStyle(Ink.muted)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    static func phaseName(_ op: String) -> String {
        switch op {
        case "connect": return "Connect"
        case "init": return "Handshake"
        case "settle": return "Settle"
        case "open": return "Open session"
        case "ok-wait": return "Wait for OK"
        case "setup": return "Gallery setup"
        case "prep": return "File props"
        case "info": return "Object info"
        case "partial": return "Transfer"
        case "save": return "Save"
        case "thumb": return "Thumbnails"
        case "reconnect": return "Reconnect"
        case "net": return "Network"
        case "ble": return "Bluetooth"
        default: return op.capitalized
        }
    }

    // MARK: Files

    private func fileList(_ report: Report) -> some View {
        section("Files", symbol: "photo.on.rectangle") {
            ForEach(Array(report.files.enumerated()), id: \.offset) { _, file in
                row(symbol: file.stalls > 0 ? "exclamationmark.arrow.triangle.2.circlepath" : (file.chunks > 0 ? "checkmark.circle" : "minus.circle"),
                    tint: file.stalls > 0 ? Ink.bad : (file.chunks > 0 ? Ink.good : Ink.muted),
                    title: file.name,
                    detail: file.chunks > 0
                        ? [ByteFormat.string(file.bytes), String(format: "%.1f MB/s", file.mbPerSecond), Diagnostics.ms(file.totalMs), file.stalls > 0 ? "\(file.stalls) stall\(file.stalls == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: " · ")
                        : file.state)
            }
        }
    }

    // MARK: History

    private var historyList: some View {
        let reports = history.filter { $0.pathExtension == "txt" }
        return section("History", symbol: "clock.arrow.circlepath", trailing: {
            if !history.isEmpty {
                ShareLink(items: history) {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.ink)
                .help("Share every report")
            }
        }) {
            if reports.isEmpty {
                Text("No reports yet.")
                    .font(Ink.side(.detail))
                    .foregroundStyle(Ink.ink2)
            }
            ForEach(reports.prefix(30), id: \.path) { url in
                let info = Self.describe(url)
                let run = summaries[url.path]
                let current = shownURL == url
                HStack(spacing: 10) {
                    Button { open(url) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: run.map { $0.result.ok ? "checkmark.circle" : "exclamationmark.triangle" } ?? info.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(run.map { $0.result.ok ? Ink.good : Ink.bad } ?? Ink.muted)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.map(headline) ?? info.title).font(Ink.side(.title)).foregroundStyle(Ink.ink)
                                Text(run == nil ? info.detail : "\(info.detail) · \(info.title)").font(Ink.side(.detail)).foregroundStyle(Ink.ink2)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: info.symbol)
                                .font(.system(size: 12))
                                .foregroundStyle(Ink.muted)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(current ? Ink.surface2 : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show this report")
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(Ink.surface2, in: Circle())
                    }
                    .buttonStyle(InkPress())
                    .foregroundStyle(Ink.ink)
                    .help("Share this report")
                }
            }
        }
    }

    /// "20260927-075047-wifi-browse" to a date, a transport icon and what the run was for.
    static func describe(_ url: URL) -> (title: String, detail: String, symbol: String) {
        let stamp = url.deletingPathExtension().lastPathComponent
        let parts = stamp.split(separator: "-").map(String.init)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd-HHmmss"
        let date = parts.count >= 2 ? format.date(from: "\(parts[0])-\(parts[1])") : nil
        let rest = Array(parts.dropFirst(2))
        let transport = rest.first ?? ""
        let use = rest.dropFirst().first ?? "import"
        let symbol: String
        switch transport {
        case "usb": symbol = "cable.connector"
        case "wifi", "camera": symbol = "wifi"
        case "virtual": symbol = "testtube.2"
        default: symbol = "doc.text"
        }
        let what: String
        switch use {
        case "browse": what = "Browse"
        case "open": what = "Full-size look"
        case "bridge", "latch", "xapp": what = "Test bench · \(use == "xapp" ? "XApp replay" : "Fuji Bridge")"
        default: what = "Import"
        }
        let over = transport == "usb" ? "USB" : (transport == "virtual" ? "simulated" : "Wi-Fi")
        return (what, [date.map(SidebarDetails.when), over].compactMap { $0 }.joined(separator: " · "), symbol)
    }

    private func open(_ txt: URL, animated: Bool = true) {
        guard let report = summaries[txt.path] ?? Self.load(txt) else { return }
        withAnimation(animated ? .snappy : nil) {
            shown = report
            shownURL = txt
            shownFiles = ["txt", "json", "jsonl"].map { txt.deletingPathExtension().appendingPathExtension($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    static func load(_ txt: URL) -> Report? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: txt.deletingPathExtension().appendingPathExtension("json")) else { return nil }
        return try? decoder.decode(Report.self, from: data)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Ink.rule).frame(height: 1)
            HStack(spacing: 16) {
                if let model {
                    NavigationLink {
                        LabView(model: model)
                    } label: {
                        Label("Test bench", systemImage: "testtube.2")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.ink2)
                }
                Spacer()
                if !history.isEmpty {
                    Button(role: .destructive) {
                        Diagnostics.clear()
                        history = Diagnostics.history()
                        shown = nil
                    } label: {
                        Label("Delete all reports", systemImage: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.bad)
                }
            }
            .font(Ink.side(.title))
            Text("Each run keeps a report, a JSON copy and a line-by-line trace\(Ink.isMac ? "" : ", also in Files › Fuji Bridge").")
                .font(Ink.side(.detail))
                .foregroundStyle(Ink.muted)
        }
    }

    private var placeholder: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 22)).foregroundStyle(Ink.muted)
            Text("No run yet in this launch. Pick one below.")
                .font(Ink.side(.title))
                .foregroundStyle(Ink.ink2)
        }
    }

    // MARK: Pieces

    private func section<Content: View, Trailing: View>(_ title: String, symbol: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(Ink.side(.header))
                    .foregroundStyle(Ink.ink2)
                Spacer()
                trailing()
            }
            VStack(alignment: .leading, spacing: 12) { content() }
        }
    }

    private func row(symbol: String, tint: Color, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Ink.side(.title, .semibold))
                    .foregroundStyle(Ink.ink)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Ink.side(.detail))
                        .foregroundStyle(Ink.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// Icons for the stages of a run, joined by a line: done in green, the current one pulsing, the rest faint.
struct StepRail: View {
    let steps: [String]
    let current: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, symbol in
                if index > 0 {
                    Rectangle()
                        .fill(index <= current ? Ink.good.opacity(0.6) : Ink.rule)
                        .frame(height: 1.5)
                }
                ZStack {
                    Circle()
                        .fill(index < current ? Ink.good.opacity(0.18) : (index == current ? Ink.ink : Ink.paper))
                    Circle()
                        .strokeBorder(index < current ? Ink.good.opacity(0.5) : (index == current ? Ink.ink : Ink.rule), lineWidth: 1)
                    Image(systemName: index < current ? "checkmark" : symbol)
                        .font(.system(size: index < current ? 10 : 12, weight: .semibold))
                        .foregroundStyle(index < current ? Ink.good : (index == current ? Ink.paper : Ink.muted))
                        .symbolEffect(.pulse, isActive: index == current)
                }
                .frame(width: 28, height: 28)
            }
        }
    }
}

/// A status line inside the camera card: an icon, a few words, an optional second line, a trailing control.
struct CardLine<Trailing: View>: View {
    let symbol: String?
    let tint: Color
    let text: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(Ink.side(.title, .semibold))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(Ink.side(.detail))
                        .foregroundStyle(Ink.ink2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
    }
}

/// Speed, count, time left: one monospaced line, dot separated.
struct MonoLine: View {
    let items: [String]

    var body: some View {
        Text(items.joined(separator: "  ·  "))
            .font(Ink.side(.detail))
            .foregroundStyle(Ink.ink2)
            .monospacedDigit()
            .lineLimit(1)
    }
}

/// A small capsule button for the card's secondary actions.
struct SmallPill: View {
    let title: String?
    let symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                if let title { Text(title).font(Ink.prose(13, .semibold)) }
            }
            .padding(.horizontal, title == nil ? 9 : 12)
            .padding(.vertical, 6)
            .foregroundStyle(Ink.paper)
            .background(Ink.ink, in: Capsule())
        }
        .buttonStyle(InkPress())
    }
}

/// The Mac joins the camera's network by hand: its name, and two icons to copy the password and open Wi-Fi settings.
struct JoinRow: View {
    let wifi: CameraWifi
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink).frame(width: 18)
            Text(wifi.ssid)
                .font(Ink.mono(12, .medium))
                .foregroundStyle(Ink.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if !wifi.password.isEmpty {
                icon(copied ? "checkmark" : "key", help: "Copy the password") {
                    UIPasteboard.general.string = wifi.password
                    copied = true
                }
            }
            if ProcessInfo.processInfo.isMacCatalystApp, let settings = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") {
                icon("gearshape", help: "Open Wi-Fi settings (copies the password)") {
                    UIPasteboard.general.string = wifi.password
                    copied = true
                    UIApplication.shared.open(settings)
                }
            }
        }
        .padding(10)
        .background(Ink.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Ink.surface2, in: Circle())
        }
        .buttonStyle(InkPress())
        .foregroundStyle(Ink.ink)
        .help(help)
    }
}
