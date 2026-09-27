import Foundation
import Observation
import UIKit

enum BenchMode: String, CaseIterable, Identifiable {
    case virtual = "Virtual body"
    case camera = "Camera"
    var id: String { rawValue }
}

/// How many of the card's newest frames an import looks at. The rest of the card is left alone.
enum Scope: Int, CaseIterable, Identifiable {
    case latest25 = 25
    case latest100 = 100
    case all = 0
    var id: Int { rawValue }
    var label: String { self == .all ? "Whole card" : "Newest \(rawValue)" }
}

/// The photo shown full window, from either grid.
struct Viewer: Equatable {
    var tab: GalleryTab
    var id: String
}

/// What a camera run is for. All four go through the same importer.
/// A stop the user can do something about, shown instead of the generic reason.
struct StopHint: Equatable {
    var symbol: String
    var title: String
    var detail: String
    /// Opens the app's page in Settings (permissions).
    var opensSettings = false
}

enum Purpose: Equatable {
    /// The newest frames in scope that are not here yet.
    case newPhotos
    /// Frames picked in the preview grid.
    case selected(Set<Int>)
    /// Thumbnails and names only, nothing copied.
    case browse
    /// One frame into the cache, to look at full size.
    case open(Int)
    /// These frames off the card, for good.
    case delete(Set<Int>)
    /// Reads the newest frame with several window sizes and keeps the fastest. Nothing saved.
    case speedTest
}

@MainActor
@Observable
final class BenchModel {
    var mode: BenchMode = .virtual
    var faults = Faults()
    var phase = "Idle"
    var summary: String?
    var lines: [TraceLine] = []
    var files: [FileResult] = []
    var compare: [CompareRow] = []
    var selected: Set<Int> = Set(Catalog.roll.map(\.handle))
    var saved: [URL] = [] {
        didSet { if saved != oldValue { importedNames = Set(saved.map(\.lastPathComponent)) } }
    }
    var busy = false
    var waiting = false
    var progress: LiveProgress?
    var report: Report?
    var reportFiles: [URL] = []
    /// Body on USB right now ("X100VI"). When there is one, imports go over USB; otherwise over Wi-Fi.
    var usbCamera: String?
    var transport: Transport { usbCamera != nil ? .usb : .wifi }
    /// Transport of the run in progress or the last one.
    var runTransport: Transport = .wifi
    var runStarted: Date?
    var purpose: Purpose = .newPhotos
    /// The card as the last browse saw it, newest first.
    var cameraPhotos: [CardPhoto] = []
    /// How many frames the card holds, as the last listing reported it. Nil until the camera has been browsed.
    var cardTotal: Int?
    /// Set by `browseMore`: the next listing continues below what is on screen instead of replacing it.
    private var browseSkip = 0
    /// Page size for "Load more", remembered.
    var browsePage: Int = UserDefaults.standard.object(forKey: "BridgeBrowsePage") as? Int ?? 100 {
        didSet { UserDefaults.standard.set(browsePage, forKey: "BridgeBrowsePage") }
    }
    /// True while a listing runs with no limit: the grid keeps filling until the card is done or Stop.
    var browsingAll = false
    /// Frames on the card that are not listed yet.
    var cardRemaining: Int? { cardTotal.map { max($0 - cameraPhotos.count, 0) } }
    var selection: Set<Int> = []
    /// The photo open in the viewer, if any: which grid it comes from and its id there.
    var viewer: Viewer?
    /// Frames of the card copied into the cache for a full-size look, by handle.
    var fullSize: [Int: URL] = [:]
    /// A Fujifilm body heard over Bluetooth ("X100VI-THOMAS"), when Bluetooth is on for Fuji Bridge.
    var bluetoothCamera: String?
    var bluetoothEnabled = UserDefaults.standard.bool(forKey: "BridgeBluetooth")
    /// The access point the last wake returned. On the Mac the user joins it by hand, so the UI shows it.
    var cameraWifi: CameraWifi?
    var joinByHand = false
    /// The body ignored this device: it is bonded with another one. The camera card then offers to pair.
    var bluetoothNeedsPairing = false
    /// The body is bonded with this device (the pairing went through here at least once).
    var bluetoothPairedHere = false
    /// Next wake waits for the camera's pairing screen instead of connecting to a bonded body.
    private var pairingRequested = false
    /// Why the Bluetooth step failed, so the summary does not only blame the Wi-Fi.
    private var bleFailure: String?
    private var bleError: Error?
    private var lastLocalNetworkDenied = false
    /// Bluetooth on this device, as CoreBluetooth last reported it. Only known once Bluetooth is enabled in the app.
    var bluetoothPower: BluetoothPower = .unknown
    /// Why the last run stopped, in words a person can act on, when the cause is known (Bluetooth off,
    /// the join declined, Local Network denied…). Replaces the generic "camera not reachable".
    var stopHint: StopHint?
    /// Names already in the photos folder, to mark frames on the camera that are here.
    /// Names in the library, kept with `saved`. Every camera tile asks it on every redraw: rebuilding the set
    /// per call made a click on a 1,800-frame card cost hundreds of thousands of allocations.
    private(set) var importedNames: Set<String> = []
    var scope: Scope = Scope(rawValue: UserDefaults.standard.object(forKey: "BridgeScope") as? Int ?? 25) ?? .latest25 {
        didSet { UserDefaults.standard.set(scope.rawValue, forKey: "BridgeScope") }
    }
    /// Camera address. 192.168.0.1 on the body's own Wi-Fi; a Mac running tools/fakecam.py for rehearsals.
    /// Bytes per GetPartialObject over Wi-Fi. 1 MB like XApp until a speed test finds better.
    var windowSize: Int = UserDefaults.standard.object(forKey: "BridgeWindow") as? Int ?? Fuji.partialMax {
        didSet { UserDefaults.standard.set(windowSize, forKey: "BridgeWindow") }
    }
    /// Wi-Fi imports only: resized by the camera (S by default, the radio is slow), or originals.
    var importSize: ImportSize = ImportSize(rawValue: UserDefaults.standard.string(forKey: "BridgeImportSize") ?? "") ?? .small {
        didSet { UserDefaults.standard.set(importSize.rawValue, forKey: "BridgeImportSize") }
    }
    var host: String = UserDefaults.standard.string(forKey: "BridgeHost") ?? Fuji.cameraHost {
        didSet { UserDefaults.standard.set(host, forKey: "BridgeHost") }
    }

    private var control = RunControl()
    private var task: Task<Void, Never>?
    private var session: SessionLog?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var pathWatch: PathWatch?
    private var memoryObserver: NSObjectProtocol?
    /// Idle sleep would drop the Wi-Fi mid-file. The idle timer covers the phone's screen; this covers the Mac.
    private var activity: NSObjectProtocol?

    init() {
        USBCameras.shared.onChange = { [weak self] name in
            Task { @MainActor in self?.usbCamera = name }
        }
        USBCameras.shared.start()
        FujiBluetooth.shared.onCamera = { [weak self] name, advert, known in
            Task { @MainActor in
                guard let self else { return }
                self.bluetoothCamera = name
                self.bluetoothPairedHere = known
                // Bonded to another device (the phone) and never woken from here: say so before the user
                // presses Import and waits for a connection that will not come.
                if advert.kind == .reconnect && !known { self.bluetoothNeedsPairing = true }
                if advert.kind == .securePairing || advert.kind == .basicPairing || known { self.bluetoothNeedsPairing = false }
            }
        }
        FujiBluetooth.shared.onPower = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.bluetoothPower = BluetoothPower(state)
                // A body heard before Bluetooth went off is not reachable any more: do not keep showing it.
                if self.bluetoothPower != .on { self.bluetoothCamera = nil }
            }
        }
        if bluetoothEnabled {
            FujiBluetooth.shared.startScan()
            LocalNetwork.ask()
        }
        #if DEBUG
        // Scripted rehearsals:  -BridgeAutoRun camera|usb|wifi|virtual  (-BridgeScope 5 limits the card).
        if let auto = UserDefaults.standard.string(forKey: "BridgeAutoRun") {
            Task { @MainActor in
                if auto == "usb" || auto == "browse" {
                    // The browser reports the body a moment after launch.
                    for _ in 0..<50 where self.usbCamera == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
                switch auto {
                case "virtual": self.start(.bridge, mode: .virtual)
                case "wifi": self.importFromCamera(over: .wifi)
                case "browse": self.browse()
                case "viewer":
                    self.refreshSaved()
                    let index = min(UserDefaults.standard.integer(forKey: "BridgeViewerIndex"), max(self.saved.count - 1, 0))
                    if self.saved.indices.contains(index) { self.viewer = Viewer(tab: .imported, id: self.saved[index].path) }
                default: self.importFromCamera(over: self.transport)
                }
            }
        }
        #endif
    }

    /// The home screen's one button: the selection when there is one, otherwise the newest in scope.
    func importFromCamera(over transport: Transport? = nil) {
        let purpose: Purpose = selection.isEmpty ? .newPhotos : .selected(selection)
        start(.bridge, mode: .camera, transport: transport ?? self.transport, purpose: purpose)
    }

    /// Fills the preview grid with the newest frames in scope. Optional: imports never need it.
    /// Deletes these frames from the card. The caller has already asked the user; nothing here can be undone.
    func deleteFromCamera(_ handles: Set<Int>) {
        guard !handles.isEmpty else { return }
        start(.bridge, mode: .camera, transport: transport, purpose: .delete(handles))
    }

    func browse() {
        browseSkip = 0
        browsingAll = scope == .all
        start(.bridge, mode: .camera, transport: transport, purpose: .browse)
    }

    /// Lists further back into the card, below what is already on screen. Nil lists everything left, and the
    /// grid keeps filling as each thumbnail arrives ("load continuously").
    func browseMore(_ count: Int?) {
        guard !busy else { return }
        browseSkip = cameraPhotos.count
        browsingAll = count == nil
        browseLimit = count
        start(.bridge, mode: .camera, transport: transport, purpose: .browse)
    }

    /// Nil: the import scope decides (first browse). Set by `browseMore` for one run.
    private var browseLimit: Int?? = nil

    /// The frame's full-size copy in the cache, when an earlier look already fetched it whole.
    func cachedFullSize(_ photo: CardPhoto) -> URL? {
        if let known = fullSize[photo.handle] { return known }
        let cached = Self.previewFolder().appendingPathComponent(photo.name)
        let size = (try? FileManager.default.attributesOfItem(atPath: cached.path)[.size] as? NSNumber)?.intValue
        return size == photo.bytes ? cached : nil
    }

    /// Copies one frame into the cache for the viewer, unless it is there already or the camera is busy.
    func fetchFullSize(_ photo: CardPhoto) {
        if let cached = cachedFullSize(photo) {
            fullSize[photo.handle] = cached
            return
        }
        guard !busy else { return }
        start(.bridge, mode: .camera, transport: transport, purpose: .open(photo.handle))
    }

    var fetchingFullSize: Int? {
        if busy, case .open(let handle) = purpose { return handle }
        return nil
    }

    /// "Pair with the camera": wait for PAIRING REGISTRATION, bond, wake the Wi-Fi, and import.
    func pairBluetooth() {
        pairingRequested = true
        importFromCamera(over: .wifi)
    }

    /// First use asks for Bluetooth permission, then Fuji Bridge listens for the camera from then on.
    func enableBluetooth() {
        bluetoothEnabled = true
        UserDefaults.standard.set(true, forKey: "BridgeBluetooth")
        FujiBluetooth.shared.startScan()
        // The Wi-Fi import will need Local Network access: ask now, while the user is setting things up,
        // rather than in the middle of the first join, where a pending prompt looks like a failed connection.
        LocalNetwork.ask()
    }

    func toggle(_ photo: CardPhoto) {
        if selection.contains(photo.handle) { selection.remove(photo.handle) } else { selection.insert(photo.handle) }
    }

    func pressOK() {
        control.ok = true
        waiting = false
        phase = "Importing"
    }

    func stop() {
        session?.event("Stop pressed", "User stopped the run.", level: "warn")
        control.aborted = true
        task?.cancel()
    }

    /// Scene phase changes. iOS suspends the app a few seconds after it leaves the screen, and the socket goes with it.
    func lifecycle(_ phase: String) {
        if phase == "active", !busy, let pending = resumeOnReturn {
            resumeOnReturn = nil
            if Date().timeIntervalSince(pending.at) < 600 {
                start(.bridge, mode: .camera, transport: runTransport, purpose: pending.purpose)
                session?.event("Resumed", "The last import stopped when Fuji Bridge left the screen. Picking it up where it was.")
                return
            }
        }
        guard busy, let session else { return }
        // A hidden Mac window keeps running; a phone app in the background is suspended within seconds.
        let suspends = phase == "background" && !ProcessInfo.processInfo.isMacCatalystApp
        if suspends { leftScreen = true }
        session.event("App \(phase)", suspends
            ? "Left the screen during the import. iOS will suspend the socket once background time runs out."
            : "Scene is \(phase).", level: suspends ? "warn" : "info")
    }

    func start(_ kind: ClientKind, mode: BenchMode, transport: Transport = .wifi, purpose: Purpose = .newPhotos) {
        guard !busy else { return }
        self.mode = mode
        self.purpose = purpose
        if purpose == .browse && browseSkip == 0 { cameraPhotos = [] }
        runTransport = mode == .camera ? transport : .wifi
        runStarted = Date()
        control = RunControl()
        control.ok = mode == .virtual && !faults.requireOk
        lines = []
        compare = []
        summary = nil
        files = []
        progress = nil
        busy = true
        waiting = mode == .virtual && faults.requireOk
        phase = waiting ? "Waiting for OK" : (mode == .camera ? (transport == .usb ? "Opening the camera" : "Connecting") : "Importing")
        var only: Set<Int>?
        switch purpose {
        case .selected(let handles): only = handles
        case .open(let handle): only = [handle]
        case .delete(let handles): only = handles
        default: only = nil
        }
        var preview: (@Sendable (CardPhoto) -> Void)?
        var cardCount: (@Sendable (Int) -> Void)?
        if purpose == .browse {
            // Each batch arrives newest first. A first listing starts at the top; a "load more" batch is older
            // than everything shown, so it continues below what is there. Either way each photo goes after the last.
            browseCursor = browseSkip
            let known = Set(cameraPhotos.map(\.handle))
            preview = { [weak self] photo in
                Task { @MainActor [weak self] in
                    guard let self, !known.contains(photo.handle) else { return }
                    let at = min(self.browseCursor, self.cameraPhotos.count)
                    self.cameraPhotos.insert(photo, at: at)
                    self.browseCursor = at + 1
                }
            }
            cardCount = { [weak self] count in
                Task { @MainActor [weak self] in self?.cardTotal = count }
            }
        }
        let faults = self.faults
        let mode = self.mode
        let handles = selected
        let host = self.host.trimmingCharacters(in: .whitespaces)
        let control = self.control
        var latest = scope == .all ? nil : scope.rawValue
        if purpose == .speedTest { latest = 1 }
        let skipNewest = purpose == .browse ? browseSkip : 0
        if purpose == .browse, let limit = browseLimit { latest = limit }
        browseLimit = nil
        browseSkip = 0
        #if DEBUG
        let override = UserDefaults.standard.integer(forKey: "BridgeLatest")
        if override > 0 { latest = override }
        #endif
        // The label ends up in the report's name; the sidebar's history keeps only the "-import" ones.
        let use: String
        switch purpose {
        case .browse: use = "browse"
        case .open: use = "open"
        case .delete: use = "delete"
        case .speedTest: use = "speedtest"
        default: use = "import"
        }
        let session = SessionLog(label: mode == .camera ? "\(transport.rawValue)-\(use)" : "virtual-\(kind.rawValue)")
        self.session = session
        begin(session)

        let log: (TraceLine) -> Void = { [weak self] line in
            session.append(line)
            Task { @MainActor in self?.receive(line) }
        }
        let progress: @Sendable (LiveProgress) -> Void = { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }

        task = Task {
            let result: RunResult
            if mode == .virtual {
                let frames = Catalog.roll.filter { handles.contains($0.handle) }
                let body = VirtualBody(faults: faults, control: control, frames: frames)
                let link = VirtualLink(body: body)
                result = await Importer.run(
                    link: link,
                    options: RunOptions(kind: kind, frames: frames, faults: faults, control: control, paceNanos: 12_000_000, progress: progress),
                    log: log
                )
            } else {
                // Wi-Fi with a Fujifilm heard over Bluetooth: have it start its access point and join it first.
                var connectTimeout: TimeInterval = 8
                self.bleFailure = nil
                self.bleError = nil
                self.stopHint = nil
                self.leftScreen = false
                // Bluetooth on: look for the body even if it has not been heard yet (it may have just woken up).
                if transport == .wifi && self.bluetoothEnabled {
                    connectTimeout = await self.wakeAndJoin(session)
                }
                // After a Bluetooth wake the body can take its time to answer the first packet.
                // Three init attempts of 12 s each beat one of 30 s: a silent socket gets replaced (Session.swift).
                let tcp = transport == .wifi ? TCPLink(host: host, connectTimeout: connectTimeout, readTimeout: connectTimeout > 8 ? 12 : 10) : nil
                let link: ByteLink = tcp ?? USBLink()
                let opening: Bool
                if case .open = purpose { opening = true } else { opening = false }
                // A rehearsal against tools/fakecam.py (loopback) must never land in the real photo library.
                let rehearsal = transport == .wifi && (host.hasPrefix("127.") || host == "localhost")
                let dir = opening ? Self.previewFolder() : (rehearsal ? Self.rehearsalFolder() : Self.folder())
                liveLibrary = !opening && !rehearsal
                let size: ImportSize
                switch purpose {
                case .newPhotos, .selected: size = importSize
                default: size = .original
                }
                let window = transport == .wifi ? windowSize : Fuji.partialMax
                var rejoin: (@Sendable () async -> Bool)?
                if transport == .wifi && !rehearsal {
                    rejoin = { [weak self] in await self?.rejoinCamera(session) ?? false }
                }
                let benchmark: [Int]? = purpose == .speedTest ? Self.benchWindows : nil
                result = await Importer.run(
                    link: link,
                    options: RunOptions(
                        kind: .bridge,
                        frames: [],
                        faults: .none,
                        control: control,
                        paceNanos: 0,
                        live: true,
                        saveDirectory: dir,
                        host: host,
                        transport: transport,
                        latest: latest,
                        skipNewest: skipNewest,
                        cardCount: cardCount,
                        only: only,
                        preview: preview,
                        progress: progress,
                        clockOrigin: session.origin,
                        delete: { if case .delete = purpose { return true } else { return false } }(),
                        transferTimeout: 30,
                        size: size,
                        window: window,
                        rejoin: rejoin,
                        benchmark: benchmark
                    ),
                    log: log
                )
                FujiBluetooth.shared.release()
                if tcp == nil {
                    let usb = USBCameras.shared
                    session.event("ImageCaptureCore totals", String(format: "%d commands, %.0f ms inside ImageCaptureCore, %.0f ms in the hop back.", usb.commands, usb.iccMs, usb.hopMs), op: "net")
                    usb.resetCounters()
                }
                lastLocalNetworkDenied = tcp?.localNetworkDenied ?? false
                if let tcp {
                    session.event("Socket totals", "\(ByteFormat.string(tcp.bytesIn)) in over \(tcp.receives) receives, \(ByteFormat.string(tcp.bytesOut)) out.", op: "net")
                }
                saved = Self.photos()
                if purpose == .speedTest, result.ok { adoptFastestWindow(session) }
                if !result.ok, leftScreen, purpose == .newPhotos || { if case .selected = purpose { return true } else { return false } }() {
                    // Picked up again as soon as the app is back on screen; the .part files make it a resume.
                    resumeOnReturn = (purpose, Date())
                }
                if opening, let file = result.files.first {
                    let url = dir.appendingPathComponent(file.name)
                    if FileManager.default.fileExists(atPath: url.path) { fullSize[file.handle] = url }
                }
                if case .selected = purpose {
                    selection.subtract(result.files.filter { $0.state == "full" || $0.state == "already" }.map(\.handle))
                }
                if case .delete = purpose {
                    let gone = Set(result.files.filter { $0.state == "deleted" }.map(\.handle))
                    cameraPhotos.removeAll { gone.contains($0.handle) }
                    selection.subtract(gone)
                    if let total = cardTotal { cardTotal = max(total - gone.count, 0) }
                    if let viewer, viewer.tab == .camera, cameraPhotos.contains(where: { "camera-\($0.handle)" == viewer.id }) == false {
                        self.viewer = nil
                    }
                }
            }
            files = result.files.filter { ($0.state != "skipped" && $0.state != "lost") || $0.got > 0 }
            if result.reason == "still-waiting" {
                phase = "Waiting for OK"
            } else {
                phase = result.ok ? (result.reason == "deleted" ? "Deleted" : "Copied") : "Stopped"
                waiting = false
            }
            summary = result.summary
            if !result.ok, let bleFailure { summary = "Bluetooth: \(bleFailure) Then Wi-Fi: \(result.summary)" }
            if !result.ok && mode != .virtual && transport == .wifi {
                stopHint = (leftScreen ? Self.leftScreenHint : nil)
                    ?? Self.hint(ble: bleError, localNetworkDenied: lastLocalNetworkDenied)
                    ?? Self.silentCameraHint(result)
            }
            joinByHand = false
            pairingRequested = false
            if result.reason != "still-waiting" {
                busy = false
                browsingAll = false
                self.progress = nil
            }
            let label = mode == .virtual ? "Virtual body" : (transport == .usb ? "Camera USB" : "Camera Wi-Fi")
            finish(session, mode: label, host: mode == .virtual ? "virtual" : (transport == .usb ? "usb" : host), result: result)
        }
    }

    func runCompare() {
        guard !busy else { return }
        busy = true
        phase = "Comparing"
        summary = nil
        let frames = Catalog.roll.filter { selected.contains($0.handle) }
        task = Task {
            let rows = await Importer.compare(frames: frames)
            compare = rows
            phase = "Idle"
            busy = false
            summary = "Five faults, run separately. Fuji Bridge keeps the offset. XApp closes the socket."
        }
    }

    func refreshSaved() {
        saved = Self.photos()
    }

    /// This run went to the background on iOS at some point.
    @ObservationIgnored private var leftScreen = false
    /// An import cut short by leaving the screen, to start again when the app is back.
    @ObservationIgnored private var resumeOnReturn: (purpose: Purpose, at: Date)?

    /// Window sizes the speed test tries, smallest first.
    static let benchWindows = [256 * 1024, 512 * 1024, 1_048_576, 2 * 1_048_576, 4 * 1_048_576]

    func speedTest() {
        start(.bridge, mode: .camera, transport: .wifi, purpose: .speedTest)
    }

    /// After a speed test: use the fastest window size from now on, if it clearly beats the current one.
    private func adoptFastestWindow(_ session: SessionLog) {
        let rates = session.lines.filter { $0.op == "bench-total" && $0.level != "fail" && ($0.took ?? 0) > 0 }
            .compactMap { line -> (Int, Double)? in
                let label = line.title.replacingOccurrences(of: "Window ", with: "")
                guard let size = Self.benchWindows.first(where: { ByteFormat.string($0) == label }) else { return nil }
                return (size, Double(line.bytes) / (line.took ?? 1))
            }
        guard let best = rates.max(by: { $0.1 < $1.1 }) else { return }
        let current = rates.first { $0.0 == windowSize }?.1 ?? 0
        if best.0 != windowSize, best.1 > current * 1.1 {
            session.event("Window size", "Using \(ByteFormat.string(best.0)) windows from now on instead of \(ByteFormat.string(windowSize)).", op: "bench")
            windowSize = best.0
        } else {
            session.event("Window size", "Keeping \(ByteFormat.string(windowSize)) windows.", op: "bench")
        }
    }

    /// Between reconnect attempts: if the phone fell off the camera's network (iOS went back to the home Wi-Fi),
    /// join it again. True when this device has an address on the camera's network.
    private func rejoinCamera(_ session: SessionLog) async -> Bool {
        let host = self.host
        if WifiJoin.hasAddress(near: host) { return true }
        guard let wifi = cameraWifi, !ProcessInfo.processInfo.isMacCatalystApp else { return false }
        await waitForScreen(wifi.ssid, session)
        session.event("Rejoining", "No address on the camera's network any more. Joining \(wifi.ssid) again.", op: "net", level: "warn")
        _ = try? await WifiJoin.join(wifi, host: host) { title, detail in session.event(title, detail, op: "ble") }
        return WifiJoin.hasAddress(near: host)
    }

    /// iOS refuses a network join from an app that is not on screen ("application is not in the foreground").
    /// If the user switched away while the camera was waking, wait for them to come back, then join.
    private func waitForScreen(_ ssid: String, _ session: SessionLog) async {
        #if !targetEnvironment(macCatalyst)
        guard UIApplication.shared.applicationState != .active else { return }
        session.event("Waiting to join", "iOS only joins \(ssid) while Fuji Bridge is on screen. Waiting for it to come back.", op: "ble", level: "warn")
        phase = "Open Fuji Bridge to join \(ssid)"
        let deadline = Date().addingTimeInterval(300)
        while UIApplication.shared.applicationState != .active, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        phase = "Joining \(ssid)"
        #endif
    }

    /// Where the next thumbnail of the running listing goes in `cameraPhotos`.
    @ObservationIgnored private var browseCursor = 0
    /// Trace time of the first OK poll in the current wait.
    @ObservationIgnored private var okWaitSince: Double?
    /// The running import saves into the library, so its files belong in Imported.
    @ObservationIgnored private var liveLibrary = false

    private func receive(_ line: TraceLine) {
        lines.append(line)
        guard mode == .camera, busy else { return }
        if line.op != "ok-wait" { okWaitSince = nil }
        if liveLibrary, line.op == "save", line.title.hasPrefix("Saved ") {
            // Show each photo in Imported as soon as it lands, not when the whole run ends.
            let url = Self.folder().appendingPathComponent(line.detail)
            if !importedNames.contains(url.lastPathComponent) {
                let at = saved.firstIndex { $0.lastPathComponent < url.lastPathComponent } ?? saved.endIndex
                saved.insert(url, at: at)
            }
        }
        switch line.op {
        case "connect", "init", "open": phase = runTransport == .usb ? "Opening the camera" : "Connecting"
        case "net" where line.title == "Catalog ready" || line.title == "Catalog still loading": phase = "Reading the card"
        case "ok-wait":
            // The X100VI usually lets the session through by itself: only ask for OK once the poll has
            // seen the rear screen locked for a couple of seconds.
            let since = okWaitSince ?? line.ms
            okWaitSince = since
            if line.title == "DF00 = 0" && line.ms - since > 2000 { phase = "Press OK on the camera" }
        case "setup", "setup-total", "thumb": phase = "Reading the card"
        case "prep", "info", "partial", "save", "file": phase = "Copying"
        case "reconnect", "reconnect-total": phase = "Reconnecting"
        case "bench", "bench-total": phase = "Testing speed"
        case "resume": phase = "Copying"
        default: break
        }
    }

    /// Bluetooth wake, then join. Returns how long the TCP connect may wait: the Mac needs the user to pick
    /// the network, iOS needs a few seconds to associate. Failures are traced and the import still tries.
    private func wakeAndJoin(_ session: SessionLog) async -> TimeInterval {
        let ble = FujiBluetooth.shared
        ble.sink = { [weak self] title, detail in
            session.event(title, detail, op: "ble")
            if title == "Pairing" {
                Task { @MainActor in self?.phase = "Confirm the same code on the Mac and on the camera" }
            } else if title == "Bluetooth camera" {
                Task { @MainActor in self?.phase = "Connecting to the camera" }
            }
        }
        defer { ble.sink = nil }
        phase = pairingRequested ? "Waiting for the camera's pairing screen" : "Waking the camera's Wi-Fi"
        let start = Date()
        do {
            if bluetoothCamera == nil { phase = "Looking for the camera over Bluetooth" }
            // Not heard yet: give the user a minute to switch the camera on or open its pairing screen.
            let wifi = try await ble.wakeWifi(timeout: bluetoothCamera == nil ? 60 : 20, pairing: pairingRequested)
            bluetoothNeedsPairing = false
            cameraWifi = wifi
            session.event("Wi-Fi woken", "\(wifi.ssid) in \(Int(Date().timeIntervalSince(start) * 1000)) ms over Bluetooth.", op: "ble")
            phase = "Joining \(wifi.ssid)"
            await waitForScreen(wifi.ssid, session)
            let outcome = try await WifiJoin.join(wifi, host: host) { title, detail in session.event(title, detail, op: "ble") }
            joinByHand = outcome == .manual
            session.event(outcome == .joined ? "Wi-Fi joined" : "Join by hand", outcome == .joined
                ? "iOS joined \(wifi.ssid)."
                : "Pick \(wifi.ssid) in the Wi-Fi menu. Fuji Bridge waits up to 2 minutes.", op: "ble")
            if outcome == .manual { phase = "Join \(wifi.ssid) in the Wi-Fi menu" }
            return outcome == .manual ? 120 : 30
        } catch {
            session.event(error is WifiJoin.Failure ? "Wi-Fi join failed" : "Bluetooth wake failed", "\(error)", op: "ble", level: "warn")
            bleFailure = "\(error)"
            bleError = error
            if case BLEError.pairedElsewhere = error { bluetoothNeedsPairing = true }
            // Still try the Wi-Fi briefly, in case this device already joined the camera by hand.
            return 4
        }
    }

    /// Turns a known cause into words and a way out. Nil when the cause is the camera itself (off, out of range…).
    static func hint(ble: Error?, localNetworkDenied: Bool) -> StopHint? {
        let mac = ProcessInfo.processInfo.isMacCatalystApp
        if localNetworkDenied {
            return StopHint(symbol: "network.slash", title: "Local Network access is off",
                            detail: mac ? "Allow Fuji Bridge in System Settings › Privacy & Security › Local Network."
                                        : "Allow it in Settings › Fuji Bridge › Local Network.", opensSettings: !mac)
        }
        switch ble {
        case BLEError.off?:
            return StopHint(symbol: "antenna.radiowaves.left.and.right.slash", title: "Bluetooth is off",
                            detail: "Turn it on in Control Center, or plug in the cable.")
        case BLEError.unauthorized?:
            return StopHint(symbol: "hand.raised", title: "Bluetooth is not allowed",
                            detail: mac ? "Allow Fuji Bridge in System Settings › Privacy & Security › Bluetooth."
                                        : "Allow it in Settings › Fuji Bridge › Bluetooth.", opensSettings: !mac)
        case let failure as WifiJoin.Failure:
            switch failure {
            case .declined(let ssid):
                return StopHint(symbol: "wifi.exclamationmark", title: "Wi-Fi join cancelled",
                                detail: "Import again and tap Join, or pick \(ssid) in Settings › Wi-Fi.")
            case .refused(let ssid, _), .notJoined(let ssid):
                return StopHint(symbol: "wifi.exclamationmark", title: "Could not join \(ssid)",
                                detail: "Pick it in Settings › Wi-Fi, come back, and import again. The password is on the camera's Wi-Fi screen.")
            }
        default:
            return nil
        }
    }

    /// The socket opened but the body never answered the init, or shut its server during the retries
    /// (seen 27 Sept on an X100VI whose Wi-Fi was already up). Not "unreachable": the camera is right there.
    /// iOS will not join a network for an app in the background, and suspends its socket soon after.
    static let leftScreenHint = StopHint(symbol: "iphone", title: "Fuji Bridge left the screen",
                                         detail: "iOS pauses the Wi-Fi when you switch apps. Keep Fuji Bridge open until the import is done.")

    static func silentCameraHint(_ result: RunResult) -> StopHint? {
        guard result.summary.hasPrefix("Init read failed") || result.summary.hasPrefix("Reconnect failed") else { return nil }
        return StopHint(symbol: "camera", title: "The camera did not answer",
                        detail: "Switch it off and on, then import again. If it keeps happening, share the report from Diagnostics.")
    }

    /// Keeps the screen on and asks for background time, so a locked phone or a sleeping Mac does not kill the socket mid-file.
    private func begin(_ session: SessionLog) {
        UIApplication.shared.isIdleTimerDisabled = true
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Importing photos from the camera")
        background = UIApplication.shared.beginBackgroundTask(withName: "Fuji Bridge import") { [weak self] in
            session.event("Background time expired", "iOS is about to suspend Fuji Bridge. The socket will die.", level: "warn")
            Task { @MainActor in self?.endBackground() }
        }
        let watch = PathWatch()
        watch.start { path in
            session.event("Device path", path, op: "net")
        }
        pathWatch = watch
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            session.event("Memory warning", "iOS asked Fuji Bridge to free memory. Files stream to disk, so this comes from elsewhere (thumbnails, the viewer).", level: "warn")
        }
        let env = DeviceInfo.snapshot(path: "pending")
        session.event("Session", "\(env.platform), \(env.device), \(env.system), app \(env.app) (\(env.build)), thermal \(env.thermal)\(env.lowPower ? ", Low Power Mode" : "").")
    }

    private func finish(_ session: SessionLog, mode: String, host: String, result: RunResult) {
        let environment = DeviceInfo.snapshot(path: pathWatch?.current ?? "unknown")
        pathWatch?.stop()
        pathWatch = nil
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        memoryObserver = nil
        session.close()
        let report = Diagnostics.build(log: session, mode: mode, host: host, environment: environment, result: result)
        let urls = Diagnostics.save(report)
        self.report = report
        self.reportFiles = urls + [session.jsonl]
        bridgeLog.log("Report saved: \(urls.first?.path ?? "-", privacy: .public)")
        UIApplication.shared.isIdleTimerDisabled = false
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        endBackground()
        #if DEBUG
        if UserDefaults.standard.string(forKey: "BridgeAutoRun") != nil {
            print("LATCH_REPORT \(urls.first?.path ?? "-")")
            fflush(stdout)
        }
        #endif
    }

    private func endBackground() {
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
    }

    /// Finder on the Mac, the Files app on the phone. The only place the two platforms differ, and it is a URL.
    func revealPhotos() {
        let dir = Self.folder()
        let url = ProcessInfo.processInfo.isMacCatalystApp
            ? dir
            : URL(string: "shareddocuments://" + dir.path) ?? dir
        UIApplication.shared.open(url)
    }

    /// Pictures/Fuji Bridge on the Mac, Documents/Fuji Bridge (the Files app) on the phone.
    static func folder() -> URL {
        let base: FileManager.SearchPathDirectory = ProcessInfo.processInfo.isMacCatalystApp ? .picturesDirectory : .documentDirectory
        var name = "Fuji Bridge"
        #if DEBUG
        // Store screenshots: -BridgeFolder "Fuji Bridge Demo" shows a staged library instead of the real one.
        if let demo = UserDefaults.standard.string(forKey: "BridgeFolder") { name = demo }
        #endif
        let dir = FileManager.default.urls(for: base, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        // The app was called Latch: carry its Pictures/Latch over once instead of starting an empty library.
        let old = dir.deletingLastPathComponent().appendingPathComponent("Latch", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where rehearsals against the fake camera write, away from the photos.
    static func rehearsalFolder() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rehearsal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Full-size looks before importing. The system may empty it.
    static func previewFolder() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Newest first. Fuji names count up, so the name order is the shooting order.
    private static func photos() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder(), includingPropertiesForKeys: nil))?
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
    }
}
