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
    @State private var drops = FileDropCoordinator.shared
    @State private var isTargeted = false

    /// Live session from the store (the passed-in title is stable; choices update).
    private var liveSession: TerminalSession? {
        store.sessions.first { $0.id == sessionId }
    }

    var body: some View {
        VStack(spacing: 0) {
            TouchTerminalView(sessionId: sessionId, machineId: machineId)
                .ignoresSafeArea(.container, edges: .bottom)
                .dropDestination(for: URL.self) { urls, _ in
                    TouchRemoteTerminalManager.shared.sendDroppedFiles(urls, to: sessionId)
                } isTargeted: { targeted in
                    isTargeted = targeted
                }
                .overlay(alignment: .center) {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .top) { transferBanner }
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

    /// Drops stream to the Mac, so a big file takes real time — show it moving,
    /// and surface a rejection (folder / too large) rather than dropping silently.
    @ViewBuilder
    private var transferBanner: some View {
        if let name = drops.activeName {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sending \(name)")
                    .font(.caption)
                    .lineLimit(1)
                ProgressView(value: drops.fractionComplete)
                    .progressViewStyle(.linear)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(8)
            .transition(.opacity)
        } else if let error = drops.lastError {
            Text(error)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(8)
                .transition(.opacity)
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
