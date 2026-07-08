import Foundation

/// macOS worker-side `LocalTerminalHost`: forwards to the concrete singletons
/// that own real PTYs (`TerminalMirrorHub`, `TerminalManager`) and the session
/// model (`SessionStore`). Injected into `RemoteRuntime.host` at launch.
final class MacTerminalHost: LocalTerminalHost {
    static let shared = MacTerminalHost()

    func subscribeMirror(machineId: UUID, sessionId: UUID) -> (cols: Int, rows: Int, snapshot: Data)? {
        TerminalMirrorHub.shared.subscribe(machineId: machineId, sessionId: sessionId)
    }

    func unsubscribeMirror(machineId: UUID, sessionId: UUID) {
        TerminalMirrorHub.shared.unsubscribe(machineId: machineId, sessionId: sessionId)
    }

    func unsubscribeAllMirrors(machineId: UUID) {
        TerminalMirrorHub.shared.unsubscribeAll(machineId: machineId)
    }

    func sendRawInput(to sessionId: UUID, data: Data) {
        TerminalManager.shared.sendRawInput(to: sessionId, data: data)
    }

    func applyViewerResize(sessionId: UUID, cols: Int, rows: Int) {
        let c = max(20, min(500, cols))
        let r = max(5, min(200, rows))
        TerminalManager.shared.applyRemoteResize(sessionId: sessionId, cols: c, rows: r)
    }

    func restoreNaturalSizeIfUnwatched(sessionId: UUID) {
        guard TerminalMirrorHub.shared.subscribers(for: sessionId).isEmpty else { return }
        TerminalManager.shared.restoreNaturalSize(sessionId: sessionId)
    }

    func currentSessionSnapshots() -> [SessionSnapshot] {
        SessionStore.shared.currentSessionSnapshots()
    }

    func currentGroupSnapshots() -> [GroupSnapshot] {
        SessionStore.shared.projectGroups
            .filter { $0.remoteMachineId == nil }
            .map { GroupSnapshot(name: $0.name, rootPath: $0.rootPath) }
    }

    func statusUpdateMessage(for sessionId: UUID) -> StatusUpdateMessage? {
        guard let session = SessionStore.shared.sessions.first(where: { $0.id == sessionId }),
              !session.isRemote else { return nil }
        return StatusUpdateMessage(
            sessionId: session.id,
            status: session.terminalStatus,
            activityLine: session.activityLine,
            pendingPromptText: session.pendingPromptText,
            pendingChoices: session.pendingChoices,
            pendingQuestion: session.pendingQuestion,
            pendingPromptPreview: session.pendingPromptPreview,
            exchanges: Array(session.exchanges.suffix(20)),
            sentAt: Date()
        )
    }

    @discardableResult
    func createLocalSession(named name: String, workingDirectory: String) -> UUID {
        SessionStore.shared.createSession(named: name, workingDirectory: workingDirectory)
    }

    func localGroupRootPath(matchingRepo repo: String) -> String? {
        SessionStore.shared.projectGroups.first { group in
            guard let root = group.rootPath, group.remoteMachineId == nil else { return false }
            return (root as NSString).lastPathComponent == repo
                && FileManager.default.fileExists(atPath: root)
        }?.rootPath
    }
}
