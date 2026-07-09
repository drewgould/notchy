import Foundation

/// Everything one Mac publishes about itself for other Macs to mirror.
/// Written (only by its own machine) to iCloud Drive at
/// `Notchy/machines/<machineId>.json`.
nonisolated struct MachineManifest: Codable {
    var schemaVersion: Int = 1
    let machineId: UUID
    let name: String
    let hostname: String
    /// Refreshed by a heartbeat republish; viewers use it to demote spinners
    /// on manifests from machines that stopped publishing.
    let lastSeen: Date
    let sessions: [SessionSnapshot]
    /// Powers directory suggestions when creating a tab on this machine remotely.
    let groups: [GroupSnapshot]
}

/// Point-in-time mirror of one local session, embedded in the manifest and
/// used to build proxy `TerminalSession`s on viewer Macs.
nonisolated struct SessionSnapshot: Codable {
    let id: UUID
    let projectName: String
    let workingDirectory: String
    let groupName: String?
    /// Last path component of the group's git root — the cross-machine join
    /// key when both Macs have the repo checked out at different paths.
    let repoName: String?
    let status: TerminalStatus
    let activityLine: String?
    let pendingQuestion: String?
    let lastRequest: String?
    let exchanges: [TaskExchange]
    let updatedAt: Date
}

nonisolated struct GroupSnapshot: Codable {
    let name: String
    let rootPath: String?
}

/// A queued "create this tab on that Mac" request, written by the viewer to
/// `Notchy/requests/<requestId>.json`. The targeted worker consumes it:
/// deletes the file on success, or rewrites it with `status = "failed"`.
nonisolated struct RemoteCreateRequest: Codable {
    let requestId: UUID
    let sourceMachineId: UUID
    let targetMachineId: UUID
    let projectName: String
    /// Absolute path on the worker, if the viewer knows it.
    let workingDirectory: String?
    /// Fallback: match a worker group whose rootPath ends in this folder name.
    let repoName: String?
    let createdAt: Date
    var status: String = "pending"
    var error: String? = nil
}
