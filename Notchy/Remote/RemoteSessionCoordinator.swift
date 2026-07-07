import Foundation

/// Reconciles remote state into `SessionStore`: iCloud manifests (durable,
/// slow) and — once the network layer is connected — live peer updates.
/// All methods must be called on the main thread.
final class RemoteSessionCoordinator {
    static let shared = RemoteSessionCoordinator()

    /// A manifest whose publisher stopped heartbeating can't be trusted to
    /// still be working — demote spinners so they don't run forever.
    private static let staleWorkingCutoff: TimeInterval = 10 * 60

    /// Merge one machine's manifest into the store. `isPeerOnline` is never
    /// touched here — live-transport callbacks own that flag.
    func applyManifest(_ manifest: MachineManifest) {
        guard SettingsManager.shared.remoteTabsEnabled else { return }
        let store = SessionStore.shared
        // Surface every project the machine publishes — even ones with no
        // live sessions — so each is discoverable in the projects list.
        var seenProjects: Set<String?> = []
        for group in manifest.groups {
            seenProjects.insert(group.name)
            _ = store.findOrCreateRemoteGroup(
                machineId: manifest.machineId,
                machineName: manifest.name,
                projectName: group.name,
                rootPath: group.rootPath
            )
        }
        let publisherLooksAlive = Date().timeIntervalSince(manifest.lastSeen) < Self.staleWorkingCutoff
        for snapshot in manifest.sessions {
            guard !store.isRemoteSessionHidden(snapshot.id) else { continue }
            seenProjects.insert(snapshot.groupName)
            let groupId = store.findOrCreateRemoteGroup(
                machineId: manifest.machineId,
                machineName: manifest.name,
                projectName: snapshot.groupName,
                rootPath: nil
            )
            var session = TerminalSession(
                snapshot: snapshot,
                machineId: manifest.machineId,
                machineName: manifest.name,
                groupId: groupId
            )
            if !publisherLooksAlive && session.terminalStatus == .working {
                session.terminalStatus = .idle
                session.activityLine = nil
            }
            store.upsertRemoteSession(session)
        }
        store.removeRemoteSessions(for: manifest.machineId, keeping: Set(manifest.sessions.map(\.id)))
        store.pruneRemoteGroups(for: manifest.machineId, keeping: seenProjects)
    }

    /// Merge a live sessionList that just arrived over the network. Unlike a
    /// manifest, this is definitionally fresh — stamp `now` so it beats any
    /// iCloud snapshot, and mark sessions online.
    func applyLiveSessionList(machineId: UUID, machineName: String, snapshots: [SessionSnapshot]) {
        guard SettingsManager.shared.remoteTabsEnabled else { return }
        let store = SessionStore.shared
        let now = Date()
        for snapshot in snapshots {
            guard !store.isRemoteSessionHidden(snapshot.id) else { continue }
            // No pruning here — only manifests carry the authoritative group
            // list, so a live update just ensures its own groups exist.
            let groupId = store.findOrCreateRemoteGroup(
                machineId: machineId,
                machineName: machineName,
                projectName: snapshot.groupName,
                rootPath: nil
            )
            var session = TerminalSession(
                snapshot: snapshot,
                machineId: machineId,
                machineName: machineName,
                groupId: groupId
            )
            session.remoteLastUpdated = now
            session.isPeerOnline = true
            store.upsertRemoteSession(session)
        }
        store.removeRemoteSessions(for: machineId, keeping: Set(snapshots.map(\.id)))
    }

    /// Viewer side: ask another Mac to create a session. Network when the
    /// peer is online (with iCloud fallback on timeout), else straight to the
    /// durable iCloud queue for the worker to pick up whenever it's back.
    func createRemoteSession(on machineId: UUID, projectName: String, workingDirectory: String?, repoName: String?) {
        let request = RemoteCreateRequest(
            requestId: UUID(),
            sourceMachineId: MachineIdentity.id,
            targetMachineId: machineId,
            projectName: projectName,
            workingDirectory: workingDirectory,
            repoName: repoName,
            createdAt: Date()
        )
        if RemotePeerManager.shared.isPeerOnline(machineId) {
            RemotePeerManager.shared.sendCreateSession(request) { response in
                if response == nil {
                    CloudSyncManager.shared.enqueueCreateRequest(request)
                } else if let error = response?.error {
                    print("[remote] create session failed on peer: \(error)")
                }
            }
        } else {
            CloudSyncManager.shared.enqueueCreateRequest(request)
        }
    }

    /// Execute a create-request targeted at this Mac (from the iCloud queue or
    /// directly over the network). Returns the new session id, or nil with the
    /// failure written back to the request file.
    @discardableResult
    func handleCreateRequest(_ request: RemoteCreateRequest, fileURL: URL?) -> UUID? {
        let store = SessionStore.shared
        let directory: String? = {
            if let dir = request.workingDirectory.map({ ($0 as NSString).expandingTildeInPath }),
               FileManager.default.fileExists(atPath: dir) {
                return dir
            }
            if let repo = request.repoName {
                return store.projectGroups.first { group in
                    guard let root = group.rootPath, group.remoteMachineId == nil else { return false }
                    return (root as NSString).lastPathComponent == repo
                        && FileManager.default.fileExists(atPath: root)
                }?.rootPath
            }
            return nil
        }()
        guard let directory else {
            if let fileURL {
                CloudSyncManager.shared.completeRequest(request, fileURL: fileURL, error: "directory not found")
            }
            return nil
        }
        let sessionId = store.createSession(named: request.projectName, workingDirectory: directory)
        if let fileURL {
            CloudSyncManager.shared.completeRequest(request, fileURL: fileURL, error: nil)
        }
        return sessionId
    }
}
