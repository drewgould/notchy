import SwiftUI

/// Leading pill in the panel chrome that shows the active `ProjectGroup` and
/// opens a menu listing all groups + project-level actions.
struct ProjectGroupPill: View {
    @Bindable var sessionStore: SessionStore
    var foregroundOpacity: Double = 1.0

    @State private var renameText: String = ""
    @State private var showRenameDialog = false
    @State private var renameTargetId: UUID?
    @State private var newProjectText: String = ""
    @State private var showNewProjectDialog = false
    @State private var showAccountRestartDialog = false
    /// Account choice awaiting restart confirmation. nil means "Default" —
    /// `showAccountRestartDialog` alone tracks whether a switch is pending.
    @State private var pendingAccountId: UUID?
    @State private var pendingAccountGroupId: UUID?

    private var activeGroup: ProjectGroup? {
        guard let id = sessionStore.activeProjectGroupId else { return nil }
        return sessionStore.projectGroups.first { $0.id == id }
    }

    private var displayName: String {
        activeGroup?.name ?? "Project"
    }

    private var canDeleteActive: Bool {
        guard let id = sessionStore.activeProjectGroupId else { return false }
        return sessionStore.sessions.allSatisfy { $0.groupId != id }
    }

    var body: some View {
        Menu {
            ForEach(sessionStore.projectGroups) { group in
                Button {
                    sessionStore.selectGroup(group.id)
                } label: {
                    // Emoji (not an SF Symbol) so the dot renders in color — an
                    // AppKit-backed menu tints symbol icons to the label color.
                    let base = sessionStore.groupNeedsAttention(group.id)
                        ? "🔴 \(group.name)"
                        : group.name
                    // Remote groups mirror another Mac — flag them with a laptop glyph.
                    let title: Text = group.remoteMachineId != nil
                        ? Text("\(Image(systemName: "laptopcomputer")) \(base)")
                        : Text(base)
                    if group.id == sessionStore.activeProjectGroupId {
                        Label { title } icon: { Image(systemName: "checkmark") }
                    } else {
                        title
                    }
                }
            }
            if !sessionStore.projectGroups.isEmpty {
                Divider()
            }
            Button("New Project…") {
                newProjectText = ""
                showNewProjectDialog = true
            }
            // Remote projects mirror another Mac — no rename/account/delete here.
            if let active = activeGroup, active.remoteMachineId == nil {
                Button("Rename Project…") {
                    renameText = active.name
                    renameTargetId = active.id
                    showRenameDialog = true
                }
                Menu("Account") {
                    Button {
                        requestAccountChange(nil, group: active)
                    } label: {
                        if active.accountId == nil {
                            Label("Default", systemImage: "checkmark")
                        } else {
                            Text("Default")
                        }
                    }
                    if !SettingsManager.shared.accounts.isEmpty { Divider() }
                    ForEach(SettingsManager.shared.accounts) { account in
                        Button {
                            requestAccountChange(account.id, group: active)
                        } label: {
                            if active.accountId == account.id {
                                Label(account.name, systemImage: "checkmark")
                            } else {
                                Text(account.name)
                            }
                        }
                    }
                }
                Button("Delete Project", role: .destructive) {
                    sessionStore.deleteGroup(active.id)
                }
                .disabled(!canDeleteActive)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.75)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // A borderlessButton Menu draws its label through the underlying AppKit
        // control, which follows the tint color and ignores .foregroundColor —
        // without this the label renders black. See the "+" menu in PanelContentView.
        .tint(.white)
        .fixedSize()
        .alert("Rename Project", isPresented: $showRenameDialog) {
            TextField("Project name", text: $renameText)
            Button("Rename") {
                if let id = renameTargetId, !renameText.isEmpty {
                    sessionStore.renameGroup(id, to: renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Project", isPresented: $showNewProjectDialog) {
            TextField("Project name", text: $newProjectText)
            Button("Create") {
                let trimmed = newProjectText.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                let id = sessionStore.createGroup(named: trimmed)
                sessionStore.selectGroup(id)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Switch Account", isPresented: $showAccountRestartDialog) {
            Button("Restart Sessions", role: .destructive) {
                if let groupId = pendingAccountGroupId {
                    sessionStore.setAccount(pendingAccountId, forGroup: groupId)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(accountRestartMessage)
        }
        .onChange(of: showRenameDialog) { updateIsShowingDialog() }
        .onChange(of: showNewProjectDialog) { updateIsShowingDialog() }
        .onChange(of: showAccountRestartDialog) { updateIsShowingDialog() }
    }

    private func updateIsShowingDialog() {
        sessionStore.isShowingDialog = showRenameDialog || showNewProjectDialog || showAccountRestartDialog
    }

    /// Sessions in the group whose terminals are live and would be killed by an
    /// account switch.
    private func runningSessions(inGroup groupId: UUID) -> [TerminalSession] {
        sessionStore.sessions.filter { $0.groupId == groupId && $0.hasStarted }
    }

    /// Applies the account immediately when nothing is running; otherwise asks
    /// for confirmation first, since switching restarts the group's terminals.
    private func requestAccountChange(_ accountId: UUID?, group: ProjectGroup) {
        guard group.accountId != accountId else { return }
        if runningSessions(inGroup: group.id).isEmpty {
            sessionStore.setAccount(accountId, forGroup: group.id)
        } else {
            pendingAccountId = accountId
            pendingAccountGroupId = group.id
            showAccountRestartDialog = true
        }
    }

    private var accountRestartMessage: String {
        guard let groupId = pendingAccountGroupId else { return "" }
        let running = runningSessions(inGroup: groupId)
        let count = running.count == 1 ? "1 running session" : "\(running.count) running sessions"
        let base = "Switching accounts will restart \(count) in this project."
        if running.contains(where: { $0.terminalStatus == .working }) {
            return base + " Claude is currently working in at least one of them — that work will be interrupted."
        }
        return base
    }
}
