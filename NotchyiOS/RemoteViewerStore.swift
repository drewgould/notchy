import Foundation
import Observation

/// iOS-side owner of the mirrored session list. This is the viewer counterpart
/// of the macOS `SessionStore` — but a viewer-only device has no local PTYs, so
/// every session here is remote. Implements `RemoteSessionSink` so the shared
/// networking layer (`RemotePeerManager` / `RemoteSessionCoordinator`) folds
/// peer state straight into it.
@Observable
final class RemoteViewerStore: RemoteSessionSink {
    static let shared = RemoteViewerStore()

    /// All mirrored sessions across every paired Mac.
    var sessions: [TerminalSession] = []
    /// Synthetic per-machine / per-project groups rebuilt from peer state.
    var projectGroups: [ProjectGroup] = []

    /// Bumped whenever aggregate status could have changed, so the Live Activity
    /// controller can recompute. (Wired up when the Live Activity lands.)
    var statusRevision: Int = 0

    private init() {}

    // MARK: Grouping for the UI

    /// Sessions belonging to a group, in a stable order.
    func sessions(in group: ProjectGroup) -> [TerminalSession] {
        sessions.filter { $0.groupId == group.id }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Groups that currently have at least one visible session, machine-grouped.
    var populatedGroups: [ProjectGroup] {
        projectGroups
            .filter { group in sessions.contains { $0.groupId == group.id } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - RemoteSessionSink

    func setPeerOnline(_ machineId: UUID, _ online: Bool) {
        var changed = false
        for i in sessions.indices where sessions[i].originMachineId == machineId {
            if sessions[i].isPeerOnline != online {
                sessions[i].isPeerOnline = online
                changed = true
            }
        }
        if changed { statusRevision &+= 1 }
    }

    func applyRemoteStatus(_ id: UUID,
                           status: TerminalStatus,
                           activityLine: String?,
                           pendingPromptText: String?,
                           pendingChoices: [PromptChoice],
                           pendingQuestion: String?,
                           pendingPromptPreview: String?,
                           exchanges: [TaskExchange]?,
                           at timestamp: Date) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              timestamp >= (sessions[index].remoteLastUpdated ?? .distantPast) else { return }
        sessions[index].terminalStatus = status
        sessions[index].activityLine = activityLine
        sessions[index].pendingPromptText = pendingPromptText
        sessions[index].pendingChoices = pendingChoices
        sessions[index].pendingQuestion = pendingQuestion
        sessions[index].pendingPromptPreview = pendingPromptPreview
        if let exchanges { sessions[index].exchanges = exchanges }
        sessions[index].remoteLastUpdated = timestamp
        sessions[index].workingStartedAt = (status == .working)
            ? (sessions[index].workingStartedAt ?? Date())
            : nil
        statusRevision &+= 1
    }

    func upsertRemoteSession(_ session: TerminalSession) {
        guard session.isRemote, !isRemoteSessionHidden(session.id) else { return }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            guard (session.remoteLastUpdated ?? .distantPast) > (sessions[index].remoteLastUpdated ?? .distantPast) else {
                // Older snapshot — still adopt a rename (doesn't bump the status timestamp).
                if sessions[index].projectName != session.projectName {
                    sessions[index].projectName = session.projectName
                }
                return
            }
            var updated = session
            updated.isPeerOnline = sessions[index].isPeerOnline
            updated.hasBeenSelected = sessions[index].hasBeenSelected
            sessions[index] = updated
        } else {
            sessions.append(session)
        }
        statusRevision &+= 1
    }

    func removeRemoteSessions(for machineId: UUID, keeping ids: Set<UUID>) {
        let before = sessions.count
        sessions.removeAll { $0.originMachineId == machineId && !ids.contains($0.id) }
        if sessions.count != before { statusRevision &+= 1 }
    }

    @discardableResult
    func findOrCreateRemoteGroup(machineId: UUID,
                                 machineName: String,
                                 projectName: String?,
                                 rootPath: String?) -> UUID {
        let displayName = projectName.map { "\($0) (\(machineName))" } ?? machineName
        if let index = projectGroups.firstIndex(where: {
            $0.remoteMachineId == machineId && $0.remoteProjectName == projectName
        }) {
            if projectGroups[index].name != displayName {
                projectGroups[index].name = displayName
            }
            if let rootPath, projectGroups[index].rootPath != rootPath {
                projectGroups[index].rootPath = rootPath
            }
            return projectGroups[index].id
        }
        let group = ProjectGroup(name: displayName,
                                 rootPath: rootPath,
                                 remoteMachineId: machineId,
                                 remoteProjectName: projectName)
        projectGroups.append(group)
        return group.id
    }

    func pruneRemoteGroups(for machineId: UUID, keeping projectNames: Set<String?>) {
        projectGroups.removeAll { group in
            group.remoteMachineId == machineId
                && !projectNames.contains(group.remoteProjectName)
                && !sessions.contains { $0.groupId == group.id }
        }
    }

    func isRemoteSessionHidden(_ id: UUID) -> Bool {
        false  // no hide-on-viewer feature yet
    }

    func removeAllRemoteState() {
        sessions.removeAll()
        projectGroups.removeAll()
        statusRevision &+= 1
    }
}
