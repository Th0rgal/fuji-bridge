import SwiftUI
import UIKit

@main
struct FujiBridgeApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(nil)
                .background(TitlebarHider().frame(width: 0, height: 0))
        }
    }
}

/// On the Mac the title bar only repeated "Fuji Bridge" above the app. Hide its title, toolbar and rule so the
/// window buttons sit on the app's own background. Nothing to do on a phone or an iPad.
struct TitlebarHider: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Probe() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            #if targetEnvironment(macCatalyst)
            // The strip carries the grid's switch and action instead of an empty title.
            guard let scene = window?.windowScene else { return }
            MainActor.assumeIsolated { MacToolbar.shared.install(on: scene) }
            #endif
        }
    }
}
