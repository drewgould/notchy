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
    /// Non-nil marks a synthetic group holding another Mac's remote tabs.
    /// Such groups are rebuilt from iCloud manifests each launch and are never
    /// persisted, renamed, deleted, or given an account. Optional so old
    /// persisted groups decode cleanly to nil.
    var remoteMachineId: UUID?

    init(id: UUID = UUID(), name: String, rootPath: String? = nil, accountId: UUID? = nil, remoteMachineId: UUID? = nil) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.accountId = accountId
        self.remoteMachineId = remoteMachineId
    }
}
