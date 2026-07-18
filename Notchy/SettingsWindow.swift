import SwiftUI
import AppKit

enum SettingsTab: String, CaseIterable {
    case about = "About"
    case general = "General"
    case integrations = "Integrations"
    case accounts = "Accounts"

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .integrations: return "puzzlepiece"
        case .accounts: return "person.crop.circle"
        case .about: return "info.circle"
        }
    }
}

struct SettingsContentView: View {
    @State private var selectedTab: SettingsTab = .about
    var onShowNotchChanged: ((Bool) -> Void)?
    var onExternalDisplayChanged: ((Bool) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SettingsTabButton(tab: tab, isSelected: selectedTab == tab) {
                        selectedTab = tab
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)

            Divider()

            Group {
                switch selectedTab {
                case .about:
                    AboutTab()
                case .general:
                    GeneralTab(onShowNotchChanged: onShowNotchChanged, onExternalDisplayChanged: onExternalDisplayChanged)
                case .integrations:
                    IntegrationsTab()
                case .accounts:
                    AccountsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 450, height: 300)
    }
}

struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 16))
                Text(tab.rawValue)
                    .font(.system(size: 11))
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 68)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

struct GeneralTab: View {
    @Bindable private var settings = SettingsManager.shared
    var onShowNotchChanged: ((Bool) -> Void)?
    var onExternalDisplayChanged: ((Bool) -> Void)?

    var body: some View {
        Form {
            Toggle("Show notch overlay", isOn: $settings.showNotch)
                .onChange(of: settings.showNotch) { _, newValue in
                    onShowNotchChanged?(newValue)
                }
            Toggle(isOn: $settings.externalDisplayTrigger) {
                Text("External display trigger")
                Text("Hover the top-center of external displays to open the panel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: settings.externalDisplayTrigger) { _, newValue in
                onExternalDisplayChanged?(newValue)
            }
            Toggle("Enable sounds", isOn: $settings.soundsEnabled)
            Toggle(isOn: $settings.muteSoundsDuringCalls) {
                Text("Mute sounds during calls")
                Text("Silence alerts while the microphone is in use (Zoom, Meet, FaceTime, etc.)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.soundsEnabled)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct IntegrationsTab: View {
    @Bindable private var settings = SettingsManager.shared

    var body: some View {
        Form {
            Toggle(isOn: $settings.xcodeIntegrationEnabled) {
                Text("Xcode")
                Text("Detect Xcode projects automatically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: $settings.claudeIntegrationEnabled) {
                Text("Claude")
                Text("Shows real-time status updates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: $settings.claudeAutoModeEnabled) {
                Text("Auto mode")
                Text("Launch Claude with --permission-mode auto")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.claudeIntegrationEnabled)
            Toggle(isOn: $settings.remoteTabsEnabled) {
                Text("Remote tabs")
                Text("Share this Mac's sessions (\"\(MachineIdentity.displayName)\") and show other Macs' tabs, via iCloud Drive and the local network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.remoteTabsEnabled && !CloudSyncManager.shared.isAvailable {
                    Text("iCloud Drive not found — remote tabs can't sync on this Mac")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                SecureField("Anthropic API key", text: $settings.anthropicAPIKey)
                    .textFieldStyle(.roundedBorder)
                Text("Used to generate two-sentence \"next steps\" summaries when Claude finishes a task. Leave blank to disable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct AccountsTab: View {
    @Bindable private var settings = SettingsManager.shared
    @State private var newName = ""
    @State private var renameId: UUID?
    @State private var renameText = ""

    var body: some View {
        Form {
            Section("Claude Accounts") {
                if settings.accounts.isEmpty {
                    Text("No accounts yet. Add one below, then assign it to a project from the project menu in the panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.accounts) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                            Text(account.configDirURL.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Rename") {
                            renameId = account.id
                            renameText = account.name
                        }
                        Button(role: .destructive) {
                            settings.removeAccount(account.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            Section {
                HStack {
                    TextField("New account name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addAccount)
                    Button("Add", action: addAccount)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Each account uses its own Claude config directory. The first terminal you open in a project assigned to a new account will prompt you to log in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Rename Account", isPresented: Binding(
            get: { renameId != nil },
            set: { if !$0 { renameId = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let id = renameId { settings.renameAccount(id, to: renameText) }
                renameId = nil
            }
            Button("Cancel", role: .cancel) { renameId = nil }
        }
    }

    private func addAccount() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.addAccount(named: trimmed)
        newName = ""
    }
}

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("Notchy")
                .font(.title2.bold())

            Text("by Adam Lyttle")
                .font(.body)
                .foregroundStyle(.secondary)

            Button("github.com/adamlyttleapps") {
                if let url = URL(string: "https://github.com/adamlyttleapps") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(onShowNotchChanged: @escaping (Bool) -> Void, onExternalDisplayChanged: @escaping (Bool) -> Void) {
        if let existing = window {
            existing.level = .floating
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = SettingsContentView(onShowNotchChanged: onShowNotchChanged, onExternalDisplayChanged: onExternalDisplayChanged)
        let hostingView = NSHostingView(rootView: content)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Notchy Settings"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
    }
}
