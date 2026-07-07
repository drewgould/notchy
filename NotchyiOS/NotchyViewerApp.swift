import SwiftUI

/// iOS entry point for the Notchy remote viewer.
///
/// Wires the shared remote layer's platform seam to the iOS viewer store and
/// turns on remote tabs so the peer manager starts advertising/browsing over
/// the LAN. There is no `LocalTerminalHost` on iOS — this device is viewer-only.
@main
struct NotchyViewerApp: App {
    init() {
        RemoteRuntime.sink = RemoteViewerStore.shared
        RemoteRuntime.terminalSink = TouchRemoteTerminalManager.shared
        // Viewer's whole purpose is remote — always on.
        if !SettingsManager.shared.remoteTabsEnabled {
            SettingsManager.shared.remoteTabsEnabled = true
        } else {
            // Already-true doesn't re-fire the didSet that starts services.
            RemotePeerManager.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
