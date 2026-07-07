import SwiftUI

/// Drives the Mac's "Pair a Device" window: turns on remote tabs (so the
/// listener is live), shows a one-time PIN, and reports when a device pairs.
@Observable
final class MacPairingCoordinator {
    static let shared = MacPairingCoordinator()

    var pin: String = ""
    var pairedDeviceName: String?

    private init() {}

    func start() {
        pairedDeviceName = nil
        // The listener only runs when remote tabs are enabled.
        if !SettingsManager.shared.remoteTabsEnabled {
            SettingsManager.shared.remoteTabsEnabled = true
        } else {
            RemotePeerManager.shared.start()
        }
        let code = PairingManager.randomPIN()
        pin = code
        PairingManager.shared.beginPairingMode(pin: code)
        RemotePeerManager.shared.onPairingSucceeded = { [weak self] _, name in
            self?.pairedDeviceName = name
        }
    }

    func stop() {
        PairingManager.shared.endPairingMode()
        RemotePeerManager.shared.onPairingSucceeded = nil
    }
}

struct MacPairingView: View {
    @State private var coordinator = MacPairingCoordinator.shared
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let name = coordinator.pairedDeviceName {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("Paired with \(name)").font(.headline)
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            } else {
                Text("Pair a Device").font(.headline)
                Text("On your iPad, open Notchy, tap **Add Mac**, and enter this code:")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text(coordinator.pin)
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .tracking(6)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your iPad…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel", action: onDone)
            }
        }
        .padding(28)
        .frame(width: 340)
    }
}
