import Foundation

/// A named collection of `TerminalSession`s, usually corresponding to a git repository.
///
/// `rootPath` is the absolute path to the group's anchor — typically a git
/// `--show-toplevel` result. It's the key we match newly-created sessions
/// against to auto-assign them. nil means "no shared root" (a manually-created
/// group of unrelated tabs, or the catch-all for non-git sessions).
///
/// `name` is independent of `rootPath` so the user can rename groups freely
/// without losing the auto-assignment behavior.
struct ProjectGroup: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var rootPath: String?
    /// The `ClaudeAccount` this project's terminals run under, via
    /// `CLAUDE_CONFIG_DIR`. nil = the default `~/.claude` login. Optional so old
    /// persisted groups (which predate this field) decode cleanly to nil.
    var accountId: UUID?
    /// Non-nil marks a synthetic group mirroring one of another Mac's projects.
    /// Such groups are rebuilt from iCloud manifests each launch and are never
    /// persisted, renamed, deleted, or given an account. Optional so old
    /// persisted groups decode cleanly to nil.
    var remoteMachineId: UUID?
    /// For synthetic remote groups: the project's name on its origin machine —
    /// the key manifests are matched against. nil on a remote group marks the
    /// machine-level catch-all for sessions that have no group on the worker.
    /// For remote groups, `rootPath` is the project's path on the *worker*,
    /// kept so a new tab created from this group targets the right directory.
    var remoteProjectName: String?

    init(id: UUID = UUID(), name: String, rootPath: String? = nil, accountId: UUID? = nil, remoteMachineId: UUID? = nil, remoteProjectName: String? = nil) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.accountId = accountId
        self.remoteMachineId = remoteMachineId
        self.remoteProjectName = remoteProjectName
    }
}
