import SwiftUI

/// Top-level viewer screen: every mirrored session across your paired Macs,
/// grouped by project/machine, with the same status vocabulary as the notch.
struct RootView: View {
    @State private var store = RemoteViewerStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if store.populatedGroups.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .navigationTitle("Notchy")
        }
    }

    private var sessionList: some View {
        List {
            ForEach(store.populatedGroups) { group in
                Section(group.name) {
                    ForEach(store.sessions(in: group)) { session in
                        NavigationLink {
                            RemoteTerminalScreen(session: session)
                        } label: {
                            SessionRow(session: session)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Looking for your Macs", systemImage: "macbook.and.iphone")
        } description: {
            Text("Make sure Notchy is running on a Mac on this Wi-Fi network, and that this iPad is paired with it.")
        }
    }
}

/// One session row: a status indicator plus name and the most relevant subtitle
/// (live activity while working, the pending question while waiting).
struct SessionRow: View {
    let session: TerminalSession

    var body: some View {
        HStack(spacing: 12) {
            StatusIndicator(session: session)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectName)
                    .font(.body)
                    .foregroundStyle(session.isStale ? .secondary : .primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if session.isStale {
                Image(systemName: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var subtitle: String? {
        switch session.terminalStatus {
        case .working:
            return session.activityLine ?? "Working…"
        case .waitingForInput:
            return session.pendingQuestion ?? "Needs your input"
        default:
            return session.lastRequest
        }
    }
}

/// Mirrors the notch pill's icon vocabulary: spinner while working, a red
/// exclamation while waiting for input, a green check just after completion,
/// an idle dot otherwise.
struct StatusIndicator: View {
    let session: TerminalSession

    var body: some View {
        if session.isStale {
            Circle().fill(.gray).frame(width: 10, height: 10)
        } else {
            switch session.terminalStatus {
            case .working:
                ProgressView().controlSize(.small)
            case .waitingForInput:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            case .taskCompleted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .interrupted:
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.orange)
            case .idle:
                Circle().fill(.green).frame(width: 10, height: 10)
            }
        }
    }
}

