import Foundation

/// Platform seams for the remote layer.
///
/// The networking files (`RemotePeerManager`, `RemoteSessionCoordinator`,
/// `CloudSyncManager`) are shared verbatim between the macOS app and the iPad
/// viewer. They must not name `SessionStore` (which is macOS-only and imports
/// AppKit), so they talk to these two protocols instead, resolved at launch
/// through `RemoteRuntime`.
///
/// - `RemoteSessionSink` — how remote state is folded into the local model.
///   Both platforms implement it (macOS: `SessionStore`; iPad: a viewer-only
///   store).
/// - `LocalTerminalHost` — worker-side terminal operations (serving byte
///   streams, accepting input, snapshotting local sessions). macOS-only; a
///   viewer-only device leaves it nil, so inbound worker frames no-op.

// MARK: - Viewer-side model sink

/// Mutations the remote layer applies to whatever local model owns the session
/// list. Every method is already implemented by the macOS `SessionStore`.
protocol RemoteSessionSink: AnyObject {
    func setPeerOnline(_ machineId: UUID, _ online: Bool)

    func applyRemoteStatus(_ id: UUID,
                           status: TerminalStatus,
                           activityLine: String?,
                           pendingPromptText: String?,
                           pendingChoices: [PromptChoice],
                           pendingQuestion: String?,
                           pendingPromptPreview: String?,
                           exchanges: [TaskExchange]?,
                           at timestamp: Date)

    func upsertRemoteSession(_ session: TerminalSession)
    func removeRemoteSessions(for machineId: UUID, keeping ids: Set<UUID>)

    @discardableResult
    func findOrCreateRemoteGroup(machineId: UUID,
                                 machineName: String,
                                 projectName: String?,
                                 rootPath: String?) -> UUID
    func pruneRemoteGroups(for machineId: UUID, keeping projectNames: Set<String?>)

    func isRemoteSessionHidden(_ id: UUID) -> Bool
    func removeAllRemoteState()
}

// MARK: - Worker-side terminal host

/// Worker-side terminal operations — serving a session's byte stream to
/// viewers, injecting their keystrokes, and snapshotting local state for
/// manifests / session lists. Only a machine that owns real PTYs provides one.
protocol LocalTerminalHost: AnyObject {
    /// Register a viewer for a local session; returns its PTY dims plus a
    /// reset+backfill snapshot, or nil if no such session exists here.
    func subscribeMirror(machineId: UUID, sessionId: UUID) -> (cols: Int, rows: Int, snapshot: Data)?
    func unsubscribeMirror(machineId: UUID, sessionId: UUID)
    func unsubscribeAllMirrors(machineId: UUID)

    /// Inject a viewer's keystrokes into a local session's PTY.
    func sendRawInput(to sessionId: UUID, data: Data)

    /// Snapshots of this machine's local sessions / groups for manifests and
    /// session-list broadcasts.
    func currentSessionSnapshots() -> [SessionSnapshot]
    func currentGroupSnapshots() -> [GroupSnapshot]

    /// The live-state frame for one local session, or nil if it's remote/gone.
    func statusUpdateMessage(for sessionId: UUID) -> StatusUpdateMessage?

    /// Create a local session on this machine (fulfilling a remote request).
    @discardableResult
    func createLocalSession(named name: String, workingDirectory: String) -> UUID

    /// Root path of a local (non-remote) group whose folder name matches `repo`
    /// and still exists on disk — the fallback target for a create request.
    func localGroupRootPath(matchingRepo repo: String) -> String?
}

// MARK: - Viewer-side terminal sink

/// Viewer-side terminal events the network layer dispatches to whatever owns
/// the mirror views. macOS backs this with an AppKit `TerminalView`
/// (`RemoteTerminalManager`); iPad will back it with a UIKit one. The network
/// code (`RemotePeerManager`) only ever sees this protocol.
protocol RemoteTerminalSink: AnyObject {
    func peerCameOnline(_ machineId: UUID)
    func peerWentOffline(_ machineId: UUID)
    func handleSubscribeAck(_ ack: SubscribeAckMessage, from machineId: UUID)
    func handleResize(_ message: ResizeMessage, from machineId: UUID)
    func handleSessionClosed(_ sessionId: UUID, from machineId: UUID)
    func handleTermData(sessionId: UUID, bytes: Data, isSnapshot: Bool, from machineId: UUID)
}

// MARK: - Injection point

/// Set once at launch (see `AppDelegate` on macOS). The shared networking files
/// reach the local model only through these, never through a concrete store.
enum RemoteRuntime {
    static weak var sink: RemoteSessionSink?
    static weak var host: LocalTerminalHost?
    static weak var terminalSink: RemoteTerminalSink?
}
