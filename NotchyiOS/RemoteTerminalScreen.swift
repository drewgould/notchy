import SwiftUI

/// Full-screen live mirror of a remote session: the terminal fills the screen,
/// with Claude's numbered choices (when it's asking) surfaced as one-tap buttons
/// and the key-accessory bar pinned above the keyboard. Tears the subscription
/// down when dismissed.
struct RemoteTerminalScreen: View {
    let sessionId: UUID
    let machineId: UUID
    let title: String

    @State private var store = RemoteViewerStore.shared

    /// Live session from the store (the passed-in title is stable; choices update).
    private var liveSession: TerminalSession? {
        store.sessions.first { $0.id == sessionId }
    }

    var body: some View {
        VStack(spacing: 0) {
            TouchTerminalView(sessionId: sessionId, machineId: machineId)
                .ignoresSafeArea(.container, edges: .bottom)
            if let session = liveSession, !session.pendingChoices.isEmpty {
                choiceBar(session)
            }
            KeyAccessoryBar(sessionId: sessionId)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            TouchRemoteTerminalManager.shared.destroyTerminal(for: sessionId)
        }
    }

    private func choiceBar(_ session: TerminalSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let question = session.pendingQuestion {
                Text(question)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(session.pendingChoices) { choice in
                        Button {
                            TouchRemoteTerminalManager.shared.sendBytes(
                                Array("\(choice.number)".utf8), to: sessionId)
                        } label: {
                            Text("\(choice.number). \(choice.label)")
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    choice.isSelected ? Color.accentColor.opacity(0.35)
                                                      : Color(.secondarySystemBackground),
                                    in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }
}
