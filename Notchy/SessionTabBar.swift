import SwiftUI
import UniformTypeIdentifiers

struct SessionTabBar: View {
    @Bindable var sessionStore: SessionStore
    var onTabSelected: ((UUID) -> Void)? = nil

    private var visibleSessions: [TerminalSession] {
        sessionStore.sessionsInActiveGroup
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(visibleSessions) { session in
                SessionTab(
                    session: session,
                    isActive: session.id == sessionStore.activeSessionId,
                    terminalActive: session.hasStarted && sessionStore.activeXcodeProjects.contains(session.projectName),
                    terminalStatus: session.terminalStatus,
                    foregroundOpacity: sessionStore.isWindowFocused ? 1.0 : 0.6,
                    isDragging: sessionStore.draggedSessionId == session.id,
                    allGroups: sessionStore.projectGroups,
                    onSelect: {
                        sessionStore.selectSession(session.id)
                        onTabSelected?(session.id)
                    },
                    onClose: { sessionStore.closeSession(session.id) },
                    onRename: { newName in
                        sessionStore.renameSession(session.id, to: newName)
                    },
                    onMoveToGroup: { groupId in
                        sessionStore.moveSession(session.id, toGroup: groupId)
                    },
                    onMoveToNewGroup: { name in
                        let newId = sessionStore.createGroup(named: name)
                        sessionStore.moveSession(session.id, toGroup: newId)
                    }
                )
                .onDrag {
                    sessionStore.draggedSessionId = session.id
                    return NSItemProvider(object: session.id.uuidString as NSString)
                }
                .onDrop(
                    of: [.text],
                    delegate: SessionTabDropDelegate(
                        target: session,
                        sessions: $sessionStore.sessions,
                        draggedSessionId: $sessionStore.draggedSessionId,
                        onCommit: { sessionStore.persistSessionOrder() }
                    )
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SessionTabDropDelegate: DropDelegate {
    let target: TerminalSession
    @Binding var sessions: [TerminalSession]
    @Binding var draggedSessionId: UUID?
    let onCommit: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let draggedId = draggedSessionId,
              draggedId != target.id,
              let from = sessions.firstIndex(where: { $0.id == draggedId }),
              let to = sessions.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            sessions.move(
                fromOffsets: IndexSet(integer: from),
                toOffset: to > from ? to + 1 : to
            )
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedSessionId = nil
        onCommit()
        return true
    }
}

struct SessionTab: View {
    let session: TerminalSession
    let isActive: Bool
    let terminalActive: Bool
    var terminalStatus: TerminalStatus = .idle
    var foregroundOpacity: Double = 1.0
    var isDragging: Bool = false
    var allGroups: [ProjectGroup] = []
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    var onMoveToGroup: ((UUID) -> Void)? = nil
    var onMoveToNewGroup: ((String) -> Void)? = nil

    @State private var isHovering = false
    @State private var showRenameDialog = false
    @State private var renameText = ""
    @State private var latestCheckpoint: Checkpoint?
    @State private var showRestoreConfirmation = false
    @State private var showNewGroupDialog = false
    @State private var newGroupText = ""

    private var name: String { session.projectName }

    private func refreshLatestCheckpoint() {
        guard let dir = session.projectPath else { return }
        let projectDir = (dir as NSString).deletingLastPathComponent
        latestCheckpoint = CheckpointManager.shared.checkpoints(for: session.projectName, in: projectDir).first
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch terminalStatus {
        case .working:
            TabSpinnerView()
                .frame(width: 8, height: 8)
        case .waitingForInput:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.yellow)
        case .taskCompleted:
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.green)
        case .idle, .interrupted:
            Circle()
                .fill(Color.gray.opacity(0.4))
                .frame(width: 6, height: 6)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            statusIndicator

            ZStack {
                // Hidden semibold text prevents tab width change on selection
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .opacity(0)

                Text(name)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundColor(.white.opacity(foregroundOpacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                    ? Color.accentColor.opacity(0.15)
                    : isHovering ? Color.white.opacity(0.05) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .opacity(isDragging ? 0.4 : 1.0)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.arrow.push()
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture(perform: onSelect)
        .overlay(MiddleClickView { onClose() })
        .contextMenu {
//            Button("Save Checkpoint") {
//                SessionStore.shared.createCheckpointForActiveSession()
//            }
//            .disabled(session.projectPath == nil)
//
//            if latestCheckpoint != nil {
//                Button("Restore Last Checkpoint") {
//                    showRestoreConfirmation = true
//                }
//            }
//
//            Divider()
        
//            Button("Refresh") {
//                SessionStore.shared.restartSession(session.id)
//            }

            Button("Rename Tab") {
                renameText = name
                showRenameDialog = true
            }

            if !allGroups.isEmpty || onMoveToNewGroup != nil {
                Menu("Move to Project") {
                    ForEach(allGroups) { group in
                        Button {
                            onMoveToGroup?(group.id)
                        } label: {
                            if group.id == session.groupId {
                                Label(group.name, systemImage: "checkmark")
                            } else {
                                Text(group.name)
                            }
                        }
                        .disabled(group.id == session.groupId)
                    }
                    if !allGroups.isEmpty { Divider() }
                    Button("New Project…") {
                        newGroupText = ""
                        showNewGroupDialog = true
                    }
                }
            }

            Button("Close", role: .destructive) {
                onClose()
            }
        }
        .onAppear {
            refreshLatestCheckpoint()
        }
        .onChange(of: isHovering) {
            if isHovering {
                refreshLatestCheckpoint()
            }
        }
        .alert("Restore Last Checkpoint", isPresented: $showRestoreConfirmation) {
            Button("Restore", role: .destructive) {
                if let checkpoint = latestCheckpoint {
                    guard let dir = session.projectPath else { return }
                    let projectDir = (dir as NSString).deletingLastPathComponent
                    try? CheckpointManager.shared.restoreCheckpoint(checkpoint, to: projectDir)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will overwrite your current working directory with the checkpoint. Are you sure?")
        }
        .alert("Rename Tab", isPresented: $showRenameDialog) {
            TextField("Tab name", text: $renameText)
            Button("Rename") {
                if !renameText.isEmpty {
                    onRename(renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Project", isPresented: $showNewGroupDialog) {
            TextField("Project name", text: $newGroupText)
            Button("Create & Move") {
                let trimmed = newGroupText.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                onMoveToNewGroup?(trimmed)
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: showRenameDialog) {
            SessionStore.shared.isShowingDialog = showRenameDialog || showRestoreConfirmation || showNewGroupDialog
        }
        .onChange(of: showRestoreConfirmation) {
            SessionStore.shared.isShowingDialog = showRenameDialog || showRestoreConfirmation || showNewGroupDialog
        }
        .onChange(of: showNewGroupDialog) {
            SessionStore.shared.isShowingDialog = showRenameDialog || showRestoreConfirmation || showNewGroupDialog
        }
    }
}

private struct MiddleClickView: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MiddleClickNSView {
        let view = MiddleClickNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: MiddleClickNSView, context: Context) {
        nsView.action = action
    }
}

private class MiddleClickNSView: NSView {
    var action: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only claim hits during middle-click so left clicks pass through to SwiftUI
        guard let event = NSApp.currentEvent, event.type == .otherMouseDown || event.type == .otherMouseUp else {
            return nil
        }
        return super.hitTest(point)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            action?()
        } else {
            super.otherMouseUp(with: event)
        }
    }
}

struct TabSpinnerView: View {
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .trim(from: 0.05, to: 0.8)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear { isAnimating = true }
    }
}

