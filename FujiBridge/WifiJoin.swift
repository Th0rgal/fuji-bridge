import Foundation
import NetworkExtension

/// Puts this device on the camera's access point once Bluetooth has woken it.
enum WifiJoin {
    enum Outcome: Equatable {
        /// iOS joined, after its own "Fuji Bridge wants to join" prompt.
        case joined
        /// The Mac cannot be joined by an app: the user picks the network from the Wi-Fi menu.
        case manual
    }

    static func join(_ wifi: CameraWifi) async throws -> Outcome {
        #if targetEnvironment(macCatalyst)
        // NEHotspotConfiguration does not exist on the Mac, and CoreWLAN is not available to Catalyst.
        return .manual
        #else
        let configuration = wifi.password.isEmpty
            ? NEHotspotConfiguration(ssid: wifi.ssid)
            : NEHotspotConfiguration(ssid: wifi.ssid, passphrase: wifi.password, isWEP: false)
        // The body hides its SSID when Bluetooth started it (libfuji joins it as hidden too).
        configuration.hidden = true
        // Forgotten when Fuji Bridge leaves the foreground, so the phone does not keep a network without internet.
        configuration.joinOnce = true
        do {
            try await NEHotspotConfigurationManager.shared.apply(configuration)
        } catch let error as NSError where error.domain == NEHotspotConfigurationErrorDomain
            && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
            return .joined
        }
        return .joined
        #endif
    }
}
