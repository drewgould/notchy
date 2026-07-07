import Foundation

@Observable
class SettingsManager {
    static let shared = SettingsManager()

    var showNotch: Bool {
        didSet { UserDefaults.standard.set(showNotch, forKey: "replaceNotch") }
    }

    var soundsEnabled: Bool {
        didSet { UserDefaults.standard.set(soundsEnabled, forKey: "soundsEnabled") }
    }

    var muteSoundsDuringCalls: Bool {
        didSet { UserDefaults.standard.set(muteSoundsDuringCalls, forKey: "muteSoundsDuringCalls") }
    }

    var xcodeIntegrationEnabled: Bool {
        didSet { UserDefaults.standard.set(xcodeIntegrationEnabled, forKey: "xcodeIntegrationEnabled") }
    }

    var claudeIntegrationEnabled: Bool {
        didSet { UserDefaults.standard.set(claudeIntegrationEnabled, forKey: "claudeIntegrationEnabled") }
    }

    var claudeAutoModeEnabled: Bool {
        didSet { UserDefaults.standard.set(claudeAutoModeEnabled, forKey: "claudeAutoModeEnabled") }
    }

    var externalDisplayTrigger: Bool {
        didSet { UserDefaults.standard.set(externalDisplayTrigger, forKey: "externalDisplayTrigger") }
    }

    /// Remote tabs: publish this Mac's sessions (iCloud Drive + local network)
    /// and mirror other Macs' sessions as remote tabs.
    var remoteTabsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(remoteTabsEnabled, forKey: "remoteTabsEnabled")
            if remoteTabsEnabled {
                CloudSyncManager.shared.start()
                RemotePeerManager.shared.start()
            } else {
                RemotePeerManager.shared.stop()
                CloudSyncManager.shared.stop()
                RemoteRuntime.sink?.removeAllRemoteState()
            }
        }
    }

    /// Anthropic API key used by SummaryService to generate "next steps" summaries
    /// when a Claude Code task completes. Stored in UserDefaults for now.
    var anthropicAPIKey: String {
        didSet { UserDefaults.standard.set(anthropicAPIKey, forKey: "anthropicAPIKey") }
    }

    /// Claude Code accounts the user has defined. A `ProjectGroup` references one
    /// by id to run its terminals under that account's `CLAUDE_CONFIG_DIR`.
    var accounts: [ClaudeAccount] {
        didSet { persistAccounts() }
    }

    private static let accountsKey = "claudeAccounts"

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "replaceNotch") == nil { defaults.set(true, forKey: "replaceNotch") }
        if defaults.object(forKey: "soundsEnabled") == nil { defaults.set(true, forKey: "soundsEnabled") }
        if defaults.object(forKey: "muteSoundsDuringCalls") == nil { defaults.set(false, forKey: "muteSoundsDuringCalls") }
        if defaults.object(forKey: "xcodeIntegrationEnabled") == nil { defaults.set(true, forKey: "xcodeIntegrationEnabled") }
        if defaults.object(forKey: "claudeIntegrationEnabled") == nil { defaults.set(true, forKey: "claudeIntegrationEnabled") }
        if defaults.object(forKey: "claudeAutoModeEnabled") == nil { defaults.set(true, forKey: "claudeAutoModeEnabled") }
        if defaults.object(forKey: "externalDisplayTrigger") == nil { defaults.set(false, forKey: "externalDisplayTrigger") }

        showNotch = defaults.bool(forKey: "replaceNotch")
        soundsEnabled = defaults.bool(forKey: "soundsEnabled")
        muteSoundsDuringCalls = defaults.bool(forKey: "muteSoundsDuringCalls")
        xcodeIntegrationEnabled = defaults.bool(forKey: "xcodeIntegrationEnabled")
        claudeIntegrationEnabled = defaults.bool(forKey: "claudeIntegrationEnabled")
        claudeAutoModeEnabled = defaults.bool(forKey: "claudeAutoModeEnabled")
        externalDisplayTrigger = defaults.bool(forKey: "externalDisplayTrigger")
        remoteTabsEnabled = defaults.bool(forKey: "remoteTabsEnabled")
        anthropicAPIKey = defaults.string(forKey: "anthropicAPIKey") ?? ""

        if let data = defaults.data(forKey: Self.accountsKey),
           let decoded = try? JSONDecoder().decode([ClaudeAccount].self, from: data) {
            accounts = decoded
        } else {
            accounts = []
        }
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
    }

    /// Creates a new account with a stable config-dir folder and returns it.
    @discardableResult
    func addAccount(named name: String) -> ClaudeAccount {
        let id = UUID()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let account = ClaudeAccount(
            id: id,
            name: trimmed.isEmpty ? "Account" : trimmed,
            folderName: ClaudeAccount.makeFolderName(from: trimmed, id: id)
        )
        accounts.append(account)
        return account
    }

    func renameAccount(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].name = trimmed
    }

    func removeAccount(_ id: UUID) {
        accounts.removeAll { $0.id == id }
    }

    func account(for id: UUID?) -> ClaudeAccount? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }
}
