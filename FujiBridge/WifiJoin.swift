import Foundation
import Network
import NetworkExtension

/// Puts this device on the camera's access point once Bluetooth has woken it.
enum WifiJoin {
    enum Outcome: Equatable {
        /// iOS joined, after its own "Fuji Bridge wants to join" prompt, and has an address on the camera's network.
        case joined
        /// The Mac cannot be joined by an app: the user picks the network from the Wi-Fi menu.
        case manual
    }

    enum Failure: Error, CustomStringConvertible {
        /// "Cancel" on the system prompt.
        case declined(String)
        /// iOS refused the configuration or could not associate (wrong password, network gone…).
        case refused(String, String)
        /// iOS said yes, but this device never got an address on the camera's network.
        case notJoined(String)

        var description: String {
            switch self {
            case .declined(let ssid): return "Joining \(ssid) was cancelled"
            case .refused(let ssid, let why): return "iOS could not join \(ssid): \(why)"
            case .notJoined(let ssid): return "This device did not end up on \(ssid)"
            }
        }
    }

    static func join(_ wifi: CameraWifi, host: String, log: (String, String) -> Void) async throws -> Outcome {
        #if targetEnvironment(macCatalyst)
        // NEHotspotConfiguration does not exist on the Mac, and CoreWLAN is not available to Catalyst.
        return .manual
        #else
        // The body hides its SSID when Bluetooth started it (libfuji joins it as hidden too). Some firmware
        // broadcasts it anyway, and a hidden join of a visible network can fail: try the other way once.
        var lastError: Error?
        // A home router often uses 192.168.0.x too: an address there before the join proves nothing.
        let before = addresses(near: host)
        for hidden in [true, false] {
            let configuration = wifi.password.isEmpty
                ? NEHotspotConfiguration(ssid: wifi.ssid)
                : NEHotspotConfiguration(ssid: wifi.ssid, passphrase: wifi.password, isWEP: false)
            configuration.hidden = hidden
            // Forgotten when Fuji Bridge leaves the foreground, so the phone does not keep a network without internet.
            configuration.joinOnce = true
            do {
                try await NEHotspotConfigurationManager.shared.apply(configuration)
                log("Join accepted", "iOS applied \(wifi.ssid) (\(hidden ? "hidden" : "visible")). Waiting for an address on it.")
            } catch let error as NSError where error.domain == NEHotspotConfigurationErrorDomain {
                switch NEHotspotConfigurationError(rawValue: error.code) {
                case .alreadyAssociated:
                    log("Join", "Already on \(wifi.ssid).")
                case .userDenied:
                    throw Failure.declined(wifi.ssid)
                default:
                    log("Join refused", "\(hidden ? "Hidden" : "Visible") join of \(wifi.ssid): \(error.localizedDescription) (code \(error.code)).")
                    lastError = Failure.refused(wifi.ssid, error.localizedDescription)
                    continue
                }
            }
            // apply() returns once iOS accepts the configuration, not once the phone is on the network.
            // Wait until an interface has an address next to the camera, then the socket has a route.
            if await onNetwork(of: host, changedFrom: before, within: 15) { return .joined }
            if !before.isEmpty {
                // Already on a 192.168.0.x network and nothing changed: cannot tell the router from the camera.
                // Go on and let the socket decide, as before this check existed.
                log("Join unverified", "This device was already on \(before.sorted().joined(separator: ", ")); the address did not change.")
                return .joined
            }
            log("Not joined", "No address next to \(host) 15 s after \(hidden ? "the hidden" : "the visible") join.")
            lastError = Failure.notJoined(wifi.ssid)
        }
        throw lastError ?? Failure.notJoined(wifi.ssid)
        #endif
    }

    /// True once a Wi-Fi interface holds an IPv4 address in the camera's /24 (the body hands out 192.168.0.x)
    /// that it did not hold before the join.
    static func onNetwork(of host: String, changedFrom before: Set<String> = [], within seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            let now = addresses(near: host)
            if !now.isEmpty && now != before { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        } while Date() < deadline
        return false
    }

    static func hasAddress(near host: String) -> Bool { !addresses(near: host).isEmpty }

    /// IPv4 addresses on Wi-Fi-like interfaces (en*) in the same /24 as `host`.
    static func addresses(near host: String) -> Set<String> {
        let prefix = host.split(separator: ".").prefix(3).joined(separator: ".") + "."
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: Set<String> = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name).hasPrefix("en") else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST)
            let text = String(cString: name)
            if text.hasPrefix(prefix) { found.insert(text) }
        }
        return found
    }
}

/// iOS asks "Allow Fuji Bridge to find devices on your local network?" the first time the app reaches one.
/// If that first time is the import's socket, the prompt sits over a connection that looks like it failed.
/// Browsing for our own Bonjour type (declared in Info.plist) raises the prompt on purpose, earlier.
enum LocalNetwork {
    private static var browser: NWBrowser?

    static func ask() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: "_fujibridge._tcp", domain: nil), using: parameters)
        b.stateUpdateHandler = { _ in }
        b.start(queue: .main)
        browser = b
        // The prompt stays up on its own; the browser only has to exist long enough to trigger it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            browser?.cancel()
            browser = nil
        }
    }
}
