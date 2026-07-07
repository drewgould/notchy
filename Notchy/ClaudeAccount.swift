import Foundation

/// A named Claude Code account. Each account maps to its own config directory
/// (`~/.notchy/accounts/<folderName>`), which is passed to the spawned shell as
/// `CLAUDE_CONFIG_DIR`. That directory holds the account's own credentials, so
/// assigning different accounts to different `ProjectGroup`s lets each project
/// run `claude` logged in as a different user.
///
/// `folderName` is generated once at creation and never changes, so renaming the
/// account (which only touches `name`) never orphans an existing login.
struct ClaudeAccount: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let folderName: String

    init(id: UUID = UUID(), name: String, folderName: String) {
        self.id = id
        self.name = name
        self.folderName = folderName
    }

    /// Absolute config directory for this account, e.g. `~/.notchy/accounts/work-1a2b3c4d`.
    var configDirURL: URL {
        Self.accountsRoot.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Root directory holding every account's config dir.
    static var accountsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".notchy/accounts", isDirectory: true)
    }

    /// Builds a stable, filesystem-safe folder name from the display name plus a
    /// short slice of the account id (guards against collisions between accounts
    /// that slug to the same string).
    static func makeFolderName(from name: String, id: UUID) -> String {
        let allowed = CharacterSet.alphanumerics
        let slug = String(name.lowercased().unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        })
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = trimmed.isEmpty ? "account" : trimmed
        return "\(base)-\(id.uuidString.prefix(8).lowercased())"
    }
}
