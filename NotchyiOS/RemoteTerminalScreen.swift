import SwiftUI

/// Full-screen live mirror of a remote session: the terminal fills the screen
/// with the key-accessory bar pinned above the keyboard. Tears the subscription
/// down when dismissed.
struct RemoteTerminalScreen: View {
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            if let machineId = session.originMachineId {
                TouchTerminalView(sessionId: session.id, machineId: machineId)
                    .ignoresSafeArea(.container, edges: .bottom)
                KeyAccessoryBar(sessionId: session.id)
            } else {
                ContentUnavailableView("Not a remote session", systemImage: "questionmark")
            }
        }
        .navigationTitle(session.projectName)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            TouchRemoteTerminalManager.shared.destroyTerminal(for: session.id)
        }
    }
}
