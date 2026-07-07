import AppKit
import AVFoundation
import SwiftUI

extension Notification.Name {
    static let NotchyHidePanel = Notification.Name("NotchyHidePanel")
    static let NotchyExpandPanel = Notification.Name("NotchyExpandPanel")
    static let NotchyNotchStatusChanged = Notification.Name("NotchyNotchStatusChanged")

}

@Observable
class SessionStore {
    static let shared = SessionStore()

    var sessions: [TerminalSession] = []
    var activeSessionId: UUID?

    /// All known project groups. Auto-populated as new git roots are discovered;
    /// also editable by the user (rename, delete-when-empty, new).
    var projectGroups: [ProjectGroup] = []
    /// Group whose tabs are currently visible in the tab bar. nil only briefly
    /// before the first group exists.
    var activeProjectGroupId: UUID? {
        didSet {
            if let id = activeProjectGroupId {
                UserDefaults.standard.set(id.uuidString, forKey: Self.activeGroupKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeGroupKey)
            }
        }
    }
    var isPinned: Bool = {
        if UserDefaults.standard.object(forKey: "isPinned") == nil { return true }
        return UserDefaults.standard.bool(forKey: "isPinned")
    }() {
        didSet {
            UserDefaults.standard.set(isPinned, forKey: "isPinned")
            updatePollingTimer()
        }
    }
    var isTerminalExpanded = true
    var isWindowFocused = true
    var isShowingDialog = false
    var hasCompletedInitialDetection = false

    /// Non-nil while the user is mid drag-reorder of a tab. Lifted out of
    /// `SessionTabBar` so other views observing `sessions` (notably the
    /// Conductor) can freeze their layout while the array churns.
    var draggedSessionId: UUID?

    /// The most recent checkpoint for the active session, used to show the undo button
    var lastCheckpoint: Checkpoint?
    /// Project name associated with lastCheckpoint
    var lastCheckpointProjectName: String?
    /// Project directory associated with lastCheckpoint
    var lastCheckpointProjectDir: String?

    /// Non-nil while a checkpoint operation is in progress (e.g. "Taking checkpoint…", "Restoring checkpoint…")
    var checkpointStatus: String?

    /// Projects the user explicitly closed.
    /// Value is `false` while the project is still open in Xcode (suppress recreation),
    /// flips to `true` once we observe the project absent — next detection will recreate the tab.
    private var dismissedProjects: [String: Bool] = [:]

    /// Activity token to prevent macOS idle sleep while Claude is working
    private var sleepActivity: NSObjectProtocol?

    /// Sound playback
    private var audioPlayer: AVAudioPlayer?
    private var lastSoundPlayedAt: Date = .distantPast

    /// Timer that periodically checks for new Xcode projects while pinned
    private var pollingTimer: Timer?
    private static let pollingInterval: TimeInterval = 5

    var activeSession: TerminalSession? {
        sessions.first { $0.id == activeSessionId }
    }

    /// Currently open Xcode project names (refreshed on each scan)
    var activeXcodeProjects: Set<String> = []

    /// The status color for the notch (matches tab bar colors)
    var notchStatusColor: NSColor {
        guard let session = activeSession else { return .systemGreen }
        switch session.terminalStatus {
        case .waitingForInput: return .systemRed
        case .working: return .systemYellow
        case .idle, .interrupted, .taskCompleted: return .systemGreen
        }
    }

    private static let sessionsKey = "persistedSessions"
    private static let activeSessionKey = "activeSessionId"
    private static let groupsKey = "projectGroups"
    private static let activeGroupKey = "activeProjectGroupId"

    /// Cache of resolved git roots keyed by working directory. Avoids re-spawning
    /// `git` for repeated lookups in the same dir (e.g. multiple sessions sharing it).
    private var gitRootCache: [String: String?] = [:]

    init() {
        restoreGroups()
        restoreSessions()
        backfillMissingGroupIds()
        restoreActiveGroup()
        updatePollingTimer()
    }

    // MARK: - Session Persistence

    private func restoreGroups() {
        guard let data = UserDefaults.standard.data(forKey: Self.groupsKey),
              let decoded = try? JSONDecoder().decode([ProjectGroup].self, from: data) else { return }
        projectGroups = decoded
    }

    private func restoreActiveGroup() {
        if let saved = UserDefaults.standard.string(forKey: Self.activeGroupKey),
           let uuid = UUID(uuidString: saved),
           projectGroups.contains(where: { $0.id == uuid }) {
            activeProjectGroupId = uuid
        } else {
            // Follow the active session if we have one, otherwise the first group.
            activeProjectGroupId = activeSession?.groupId ?? projectGroups.first?.id
        }
    }

    /// Resolves git roots for any session whose `groupId` is nil (pre-feature
    /// data) and finds-or-creates the matching `ProjectGroup`. Runs synchronously
    /// at launch — git rev-parse is cheap and this is a one-time pass per session.
    private func backfillMissingGroupIds() {
        var changed = false
        for i in sessions.indices where sessions[i].groupId == nil {
            let groupId = findOrCreateGroup(for: sessions[i])
            sessions[i].groupId = groupId
            changed = true
        }
        if changed {
            persistGroups()
            persistSessions()
        }
    }

    private func restoreSessions() {
        guard let data = UserDefaults.standard.data(forKey: Self.sessionsKey),
              let persisted = try? JSONDecoder().decode([PersistedSession].self, from: data),
              !persisted.isEmpty else { return }
        sessions = persisted.map { TerminalSession(persisted: $0) }
        if let savedId = UserDefaults.standard.string(forKey: Self.activeSessionKey),
           let uuid = UUID(uuidString: savedId),
           sessions.contains(where: { $0.id == uuid }) {
            activeSessionId = uuid
        } else {
            activeSessionId = sessions.first?.id
        }
        // Mark all restored sessions as started so terminals launch immediately
        for i in sessions.indices {
            sessions[i].hasStarted = true
            sessions[i].hasBeenSelected = true
            // One-time cleanup: collapse adjacent exchanges with identical
            // prompts that were captured by an earlier scraper-flicker bug.
            // Prefer keeping the entry that has a generated summary, the
            // verified flag, or a completion timestamp.
            sessions[i].exchanges = collapseAdjacentDuplicates(sessions[i].exchanges)
        }
        persistSessions()
    }

    private func collapseAdjacentDuplicates(_ exchanges: [TaskExchange]) -> [TaskExchange] {
        var result: [TaskExchange] = []
        for exchange in exchanges {
            if let last = result.last, last.prompt == exchange.prompt {
                result[result.count - 1] = pickBetter(last, exchange)
            } else {
                result.append(exchange)
            }
        }
        return result
    }

    private func pickBetter(_ a: TaskExchange, _ b: TaskExchange) -> TaskExchange {
        let aScore = (a.verified ? 4 : 0) + (a.summary != nil ? 2 : 0) + (a.completedAt != nil ? 1 : 0)
        let bScore = (b.verified ? 4 : 0) + (b.summary != nil ? 2 : 0) + (b.completedAt != nil ? 1 : 0)
        return bScore > aScore ? b : a
    }

    /// Cap on persisted exchanges per session — keeps UserDefaults blob small
    /// while still showing the user a meaningful history on next launch.
    private static let persistedExchangeLimit = 50

    private func persistSessions() {
        // Remote sessions are never persisted — they're rebuilt from the cached
        // iCloud manifests at launch, which stay readable offline.
        let persisted = sessions.filter { !$0.isRemote }.map { session -> PersistedSession in
            let trimmed = Array(session.exchanges.suffix(Self.persistedExchangeLimit))
            return PersistedSession(
                id: session.id,
                projectName: session.projectName,
                projectPath: session.projectPath,
                workingDirectory: session.workingDirectory,
                exchanges: trimmed,
                pendingPromptText: session.pendingPromptText,
                groupId: session.groupId
            )
        }
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: Self.sessionsKey)
        }
        if let activeId = activeSessionId {
            UserDefaults.standard.set(activeId.uuidString, forKey: Self.activeSessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeSessionKey)
        }
        CloudSyncManager.shared.schedulePublish()
        RemotePeerManager.shared.scheduleSessionListBroadcast()
    }

    /// Point-in-time snapshots of every local session — the payload shared by
    /// the iCloud manifest and the live sessionList broadcast.
    func currentSessionSnapshots() -> [SessionSnapshot] {
        let groupsById = Dictionary(uniqueKeysWithValues: projectGroups.map { ($0.id, $0) })
        return sessions.filter { !$0.isRemote }.map { session in
            let group = session.groupId.flatMap { groupsById[$0] }
            return SessionSnapshot(
                id: session.id,
                projectName: session.projectName,
                workingDirectory: session.workingDirectory,
                groupName: group?.name,
                repoName: group?.rootPath.map { ($0 as NSString).lastPathComponent },
                status: session.terminalStatus,
                activityLine: session.activityLine,
                pendingQuestion: session.pendingQuestion,
                lastRequest: session.lastRequest,
                exchanges: Array(session.exchanges.suffix(20)),
                updatedAt: Date()
            )
        }
    }

    private func persistGroups() {
        // Synthetic per-machine groups are rebuilt from manifests each launch.
        let localGroups = projectGroups.filter { $0.remoteMachineId == nil }
        if let data = try? JSONEncoder().encode(localGroups) {
            UserDefaults.standard.set(data, forKey: Self.groupsKey)
        }
    }

    // MARK: - Project Groups

    /// Shells out to `git -C <dir> rev-parse --show-toplevel` to find the
    /// repo root. Returns nil if not in a git repo or the command fails.
    /// Memoized per directory to avoid repeated work.
    private func gitRoot(for directory: String) -> String? {
        if let cached = gitRootCache[directory] {
            return cached
        }
        let result: String? = {
            guard FileManager.default.fileExists(atPath: directory) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", directory, "rev-parse", "--show-toplevel"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return nil
            }
            guard process.terminationStatus == 0,
                  let data = try? pipe.fileHandleForReading.readToEnd(),
                  let out = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        gitRootCache[directory] = result
        return result
    }

    /// Find an existing group matching the session's git root, or create one.
    /// Sessions without a git root all fall into a single "Other" sentinel group
    /// (created lazily on first need).
    private func findOrCreateGroup(for session: TerminalSession) -> UUID {
        if let root = gitRoot(for: session.workingDirectory) {
            if let existing = projectGroups.first(where: { $0.rootPath == root }) {
                return existing.id
            }
            let name = (root as NSString).lastPathComponent
            let group = ProjectGroup(name: name.isEmpty ? "Project" : name, rootPath: root)
            projectGroups.append(group)
            return group.id
        }
        if let other = projectGroups.first(where: { $0.rootPath == nil && $0.name == "Other" }) {
            return other.id
        }
        let other = ProjectGroup(name: "Other", rootPath: nil)
        projectGroups.append(other)
        return other.id
    }

    /// True when any session in the group is blocked waiting for user input —
    /// drives the "!" marker in the project switcher menu.
    func groupNeedsAttention(_ id: UUID) -> Bool {
        // isStatusLive: an offline peer's stale .waitingForInput must not nag forever.
        sessions.contains { $0.groupId == id && $0.terminalStatus == .waitingForInput && $0.isStatusLive }
    }

    /// Sessions belonging to the currently-active project group. Drives the tab bar.
    var sessionsInActiveGroup: [TerminalSession] {
        guard let activeId = activeProjectGroupId else { return sessions }
        return sessions.filter { $0.groupId == activeId }
    }

    /// Switch which group's tabs are visible. If the previously-active session
    /// isn't in the new group, fall back to that group's first session (or nil).
    func selectGroup(_ id: UUID) {
        activeProjectGroupId = id
        if let active = activeSession, active.groupId == id { return }
        if let first = sessions.first(where: { $0.groupId == id }) {
            activeSessionId = first.id
        }
        persistSessions()
    }

    /// Create a new empty group and make it active. Returns the new group's ID.
    @discardableResult
    func createGroup(named name: String) -> UUID {
        let group = ProjectGroup(name: name.isEmpty ? "Untitled" : name, rootPath: nil)
        projectGroups.append(group)
        persistGroups()
        return group.id
    }

    func renameGroup(_ id: UUID, to newName: String) {
        guard let index = projectGroups.firstIndex(where: { $0.id == id }),
              projectGroups[index].remoteMachineId == nil else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        projectGroups[index].name = trimmed
        persistGroups()
    }

    /// Assign (or clear, with nil) the Claude account a group's terminals run
    /// under, then restart the group's running sessions so their new shells
    /// pick up the account's `CLAUDE_CONFIG_DIR`.
    func setAccount(_ accountId: UUID?, forGroup groupId: UUID) {
        guard let index = projectGroups.firstIndex(where: { $0.id == groupId }),
              projectGroups[index].remoteMachineId == nil,
              projectGroups[index].accountId != accountId else { return }
        projectGroups[index].accountId = accountId
        persistGroups()
        for session in sessions where session.groupId == groupId && session.hasStarted {
            restartSession(session.id)
        }
    }

    /// Delete a group. Only succeeds if the group has no member sessions —
    /// otherwise the caller should reassign or close those sessions first.
    @discardableResult
    func deleteGroup(_ id: UUID) -> Bool {
        if let group = projectGroups.first(where: { $0.id == id }), group.remoteMachineId != nil { return false }
        guard sessions.allSatisfy({ $0.groupId != id }) else { return false }
        projectGroups.removeAll { $0.id == id }
        if activeProjectGroupId == id {
            activeProjectGroupId = projectGroups.first?.id
            if let firstId = activeProjectGroupId,
               let first = sessions.first(where: { $0.groupId == firstId }) {
                activeSessionId = first.id
            }
        }
        persistGroups()
        return true
    }

    /// Move a session into a different group. Switches the active group to match
    /// so the user sees where the tab went.
    func moveSession(_ sessionId: UUID, toGroup groupId: UUID) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
              !sessions[sIdx].isRemote,
              let group = projectGroups.first(where: { $0.id == groupId }),
              group.remoteMachineId == nil else { return }
        sessions[sIdx].groupId = groupId
        activeProjectGroupId = groupId
        activeSessionId = sessionId
        persistSessions()
    }

    /// Force-write the latest in-memory state to disk. Called from
    /// applicationWillTerminate so a draft mid-keystroke survives Cmd+Q
    /// (updatePendingPromptText doesn't persist on every keystroke).
    func flushPersistence() {
        persistSessions()
    }

    /// Eagerly boot the terminal process for every restored session so each tab
    /// is already cd'd into its saved directory (and running `claude` for project
    /// tabs with a CLAUDE.md) by the time the user reveals the panel. Without this
    /// only the active tab's `TerminalSessionView` triggers terminal creation, so
    /// inactive tabs sit cold until clicked.
    func warmUpRestoredSessions() {
        for session in sessions where session.hasStarted && !session.isRemote {
            _ = TerminalManager.shared.terminal(
                for: session.id,
                workingDirectory: session.workingDirectory,
                launchClaude: session.projectPath != nil
            )
        }
    }

    func updateWorkingDirectory(_ id: UUID, directory: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard sessions[index].workingDirectory != directory else { return }
        sessions[index].workingDirectory = directory
        persistSessions()
    }

    /// Start or stop the polling timer based on pinned state
    private func updatePollingTimer() {
        pollingTimer?.invalidate()
        pollingTimer = nil

        if isPinned {
            pollingTimer = Timer.scheduledTimer(withTimeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
                self?.detectAllXcodeProjectsAsync()
            }
        }
    }

    /// Called when the panel gains focus — trigger a fresh Xcode scan
    func panelDidBecomeKey() {
        detectAllXcodeProjectsAsync()
    }

    /// Scans for all open Xcode projects — adds new ones, updates active set.
    /// Runs AppleScript on a background thread to avoid blocking UI.
    func detectAllXcodeProjectsAsync() {
        guard SettingsManager.shared.xcodeIntegrationEnabled else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let projects = XcodeDetector.shared.detectAllProjects()
            DispatchQueue.main.async {
                self.applyDetectedProjects(projects)
            }
        }
    }

    /// Detect projects + auto-switch to frontmost, all async
    func detectAndSwitchAsync() {
        guard SettingsManager.shared.xcodeIntegrationEnabled else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let allProjects = XcodeDetector.shared.detectAllProjects()
            let frontProject = XcodeDetector.shared.detectFrontmostProject()
            DispatchQueue.main.async {
                self.applyDetectedProjects(allProjects)
                if let project = frontProject {
                    _ = self.autoSwitchToProject(project)
                }
            }
        }
    }

    private func applyDetectedProjects(_ projects: [XcodeProject]) {
        let detectedNames = Set(projects.map(\.name))
        activeXcodeProjects = detectedNames
        hasCompletedInitialDetection = true

        // Two-phase dismiss: mark absent projects, then clear ones that reappeared
        for name in dismissedProjects.keys {
            if !detectedNames.contains(name) {
                dismissedProjects[name] = true  // observed absent
            }
        }
        for name in detectedNames {
            if dismissedProjects[name] == true {
                dismissedProjects.removeValue(forKey: name)  // reappeared after absence → allow recreation
            }
        }


        var groupsChanged = false
        for project in projects {
            if let index = sessions.firstIndex(where: { !$0.isRemote && $0.projectName == project.name }) {
                // Heal sessions created while AppleScript reported no path
                // (`missing value`) — adopt the real path once detection has it.
                if !project.path.isEmpty, sessions[index].projectPath != project.path {
                    sessions[index].projectPath = project.path
                    // Only retarget the directory if no shell is running yet;
                    // a live shell's cwd is tracked via OSC 7 instead.
                    if !sessions[index].hasStarted {
                        sessions[index].workingDirectory = project.directoryPath
                    }
                }
                continue
            }
            guard dismissedProjects[project.name] == nil else { continue }
            var session = TerminalSession(
                projectName: project.name,
                projectPath: project.path,
                workingDirectory: project.directoryPath,
                started: false
            )
            let groupsBefore = projectGroups.count
            session.groupId = findOrCreateGroup(for: session)
            if projectGroups.count != groupsBefore { groupsChanged = true }
            sessions.append(session)
        }
        // First session ever — make sure something is the active group so the
        // tab bar isn't empty.
        if activeProjectGroupId == nil {
            activeProjectGroupId = projectGroups.first?.id
        }
        if groupsChanged { persistGroups() }
        persistSessions()
    }

    /// Auto-switch to existing session for a project (left-click behavior).
    /// Only switches if the session hasn't been selected before (new tab).
    func autoSwitchToProject(_ project: XcodeProject) -> Bool {
        guard dismissedProjects[project.name] == nil else { return false }

        if let index = sessions.firstIndex(where: { !$0.isRemote && $0.projectName == project.name }) {
            // Only auto-switch to tabs the user hasn't selected yet
            guard !sessions[index].hasBeenSelected else { return false }
            sessions[index].hasBeenSelected = true
            activeSessionId = sessions[index].id
            if let gid = sessions[index].groupId, gid != activeProjectGroupId {
                activeProjectGroupId = gid
            }
            startSessionIfNeeded(sessions[index].id)
            return true
        }
        return false
    }

    /// Select a tab — auto-starts the terminal only if the project's Xcode instance is active
    func selectSession(_ id: UUID) {
        activeSessionId = id
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].hasBeenSelected = true
            let session = sessions[index]
            // Follow the session into its group so the tab bar stays in sync —
            // otherwise selecting a session from the status menu / Conductor
            // leaves the visible tab bar showing a different group's tabs.
            if let gid = session.groupId, gid != activeProjectGroupId {
                activeProjectGroupId = gid
            }
            // Auto-start if it's a plain terminal (no project) or the project is
            // open in Xcode. Remote sessions never start local terminals.
            if !session.isRemote && (session.projectPath == nil || activeXcodeProjects.contains(session.projectName)) {
                startSessionIfNeeded(id)
            }
            // Expand terminal if collapsed when user taps a tab
            if !isTerminalExpanded {
                isTerminalExpanded = true
                NotificationCenter.default.post(name: .NotchyExpandPanel, object: nil)
            }
        }
        persistSessions()
    }

    /// Mark session as started (terminal will be created when view renders)
    func startSessionIfNeeded(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].isRemote else { return }
        if !sessions[index].hasStarted {
            sessions[index].hasStarted = true
        }
    }

    /// "+" button: creates a plain terminal session in the currently-active group
    /// (so the new tab shows up immediately in the visible tab bar).
    func createQuickSession() {
        var session = TerminalSession(
            projectName: "Terminal",
            started: true
        )
        let groupsBefore = projectGroups.count
        if let activeId = activeProjectGroupId,
           let activeGroup = projectGroups.first(where: { $0.id == activeId }),
           activeGroup.remoteMachineId == nil {
            session.groupId = activeId
        } else {
            // No active group, or it's another Mac's synthetic group — a local
            // terminal can't live there.
            session.groupId = findOrCreateGroup(for: session)
        }
        if projectGroups.count != groupsBefore { persistGroups() }
        sessions.append(session)
        activeSessionId = session.id
        if activeProjectGroupId == nil { activeProjectGroupId = session.groupId }
        persistSessions()
    }

    /// Create a started session in the group matching `workingDirectory`
    /// (found or created via git root) and warm its terminal immediately.
    /// Used by remote create requests, which arrive while the panel may be
    /// hidden — so unlike createQuickSession it doesn't steal the active tab.
    @discardableResult
    func createSession(named name: String, workingDirectory: String) -> UUID {
        var session = TerminalSession(
            projectName: name,
            workingDirectory: workingDirectory,
            started: true
        )
        let groupsBefore = projectGroups.count
        session.groupId = findOrCreateGroup(for: session)
        if projectGroups.count != groupsBefore { persistGroups() }
        sessions.append(session)
        if activeSessionId == nil { activeSessionId = session.id }
        if activeProjectGroupId == nil { activeProjectGroupId = session.groupId }
        persistSessions()
        _ = TerminalManager.shared.terminal(
            for: session.id,
            workingDirectory: workingDirectory,
            launchClaude: true
        )
        return session.id
    }

    func renameSession(_ id: UUID, to newName: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].projectName = newName
        persistSessions()
    }

    /// Update the in-progress prompt text the user is typing into Claude's input box.
    func updatePendingPromptText(_ id: UUID, text: String?) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        // Never wipe an existing draft on a nil scrape. The input box transiently
        // disappears between Enter and the spinner; status detection also flakes
        // and can misclassify .waitingForInput as .idle. Either way, a transient
        // nil must not destroy the draft before the .working transition can
        // freeze it as lastRequest. The freeze itself clears pendingPromptText
        // explicitly, and a fresh scrape with text will overwrite cleanly.
        if text == nil {
            return
        }
        if sessions[index].pendingPromptText != text {
            sessions[index].pendingPromptText = text
            RemotePeerManager.shared.sessionDidChange(id)
        }
    }

    /// Update the scraped activity line (Claude's spinner/status line while working).
    func updateActivityLine(_ id: UUID, line: String?) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].activityLine != line {
            sessions[index].activityLine = line
            RemotePeerManager.shared.sessionDidChange(id)
        }
    }

    /// Update the numbered choices Claude is currently presenting, the question
    /// line above them, and any preview content (e.g. an edit's diff body) above
    /// the question.
    func updatePendingChoices(_ id: UUID, choices: [PromptChoice], question: String?, preview: String?) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        if sessions[index].pendingChoices != choices {
            sessions[index].pendingChoices = choices
            changed = true
        }
        if sessions[index].pendingQuestion != question {
            sessions[index].pendingQuestion = question
            changed = true
        }
        if sessions[index].pendingPromptPreview != preview {
            sessions[index].pendingPromptPreview = preview
            changed = true
        }
        if changed {
            RemotePeerManager.shared.sessionDidChange(id)
        }
    }

    /// Send a numbered choice to the session's terminal as if the user pressed that digit.
    func submitChoice(_ id: UUID, number: Int) {
        if let session = sessions.first(where: { $0.id == id }), session.isRemote {
            guard session.isPeerOnline, let machineId = session.originMachineId else { return }
            RemotePeerManager.shared.sendTermInput(machineId: machineId, sessionId: id, bytes: Data("\(number)".utf8))
            return
        }
        TerminalManager.shared.sendInput(to: id, text: "\(number)")
    }

    /// Toggle the per-exchange "verified" checkbox in the Conductor.
    func setExchangeVerified(_ sessionId: UUID, exchangeId: UUID, _ value: Bool) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
              let eIdx = sessions[sIdx].exchanges.firstIndex(where: { $0.id == exchangeId }) else { return }
        sessions[sIdx].exchanges[eIdx].verified = value
        persistSessions()
    }

    /// Kick off an async Claude API call to summarize the task associated with
    /// `exchangeId`. Falls back silently if no API key is configured.
    func requestSummary(for sessionId: UUID, exchangeId: UUID) {
        print("[summary] requestSummary session=\(sessionId) exchange=\(exchangeId)")
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
              let eIdx = sessions[sIdx].exchanges.firstIndex(where: { $0.id == exchangeId }) else {
            print("[summary] session/exchange not found, aborting")
            return
        }
        // Remote exchanges arrive already summarized by the worker Mac.
        guard !sessions[sIdx].isRemote else { return }
        guard !SettingsManager.shared.anthropicAPIKey.isEmpty else {
            print("[summary] no Anthropic API key set — marking failed")
            sessions[sIdx].exchanges[eIdx].summaryStatus = .failed
            return
        }
        guard let snapshot = TerminalManager.shared.visibleText(for: sessionId), !snapshot.isEmpty else {
            print("[summary] visibleText returned nil/empty — marking failed")
            sessions[sIdx].exchanges[eIdx].summaryStatus = .failed
            return
        }
        let prompt = sessions[sIdx].exchanges[eIdx].prompt
        print("[summary] firing API call: snapshot=\(snapshot.count) chars, prompt=\"\(prompt)\"")
        sessions[sIdx].exchanges[eIdx].summaryStatus = .generating
        sessions[sIdx].exchanges[eIdx].summary = nil

        Task { @MainActor in
            do {
                let summary = try await SummaryService.shared.summarize(
                    terminalOutput: snapshot,
                    lastRequest: prompt
                )
                print("[summary] success: \(summary.count) chars")
                guard let s = self.sessions.firstIndex(where: { $0.id == sessionId }),
                      let e = self.sessions[s].exchanges.firstIndex(where: { $0.id == exchangeId }) else { return }
                self.sessions[s].exchanges[e].summary = summary
                self.sessions[s].exchanges[e].summaryStatus = .ready
                self.persistSessions()
            } catch {
                print("[summary] failed: \(error)")
                guard let s = self.sessions.firstIndex(where: { $0.id == sessionId }),
                      let e = self.sessions[s].exchanges.firstIndex(where: { $0.id == exchangeId }) else { return }
                self.sessions[s].exchanges[e].summaryStatus = .failed
                self.persistSessions()
            }
        }
    }

    func updateTerminalStatus(_ id: UUID, status: TerminalStatus) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        // Defensive: only local scrapers call this today, but remote sessions
        // must never run the transition side effects — their status arrives
        // pre-digested via applyRemoteStatus.
        guard !sessions[index].isRemote else { return }
        // Whatever transition happens below, viewers should hear about it.
        defer { RemotePeerManager.shared.sessionDidChange(id) }

        // Esc was pressed: mark the in-progress exchange as interrupted+dismissed
        // and collapse the session straight to idle so the orange "Interrupted"
        // pill doesn't linger. Bypasses the normal transition handlers below —
        // we don't want sleep prevention, taskCompleted delays, or summarization
        // firing for an interrupted run.
        if status == .interrupted {
            if let lastIdx = sessions[index].exchanges.indices.last,
               sessions[index].exchanges[lastIdx].completedAt == nil {
                sessions[index].exchanges[lastIdx].completedAt = Date()
                sessions[index].exchanges[lastIdx].wasInterrupted = true
                sessions[index].exchanges[lastIdx].verified = true
                sessions[index].exchanges[lastIdx].summaryStatus = .none
                persistSessions()
            }
            if sessions[index].terminalStatus != .idle {
                sessions[index].terminalStatus = .idle
                sessions[index].activityLine = nil
                sessions[index].workingStartedAt = nil
                updateSleepPrevention()
            }
            return
        }

        if sessions[index].terminalStatus != status {
            let previous = sessions[index].terminalStatus
            print("[status] \(sessions[index].projectName): \(previous) → \(status)")
            sessions[index].terminalStatus = status
            if status != .working {
                sessions[index].activityLine = nil
            }
            updateSleepPrevention()

            if status == .working && previous != .working {
                sessions[index].workingStartedAt = Date()
                // User just submitted a request — freeze the pending text as a
                // new exchange. Don't gate on previous == .waitingForInput:
                // status can flicker through .idle between waitingForInput and
                // working (input box disappears briefly before the spinner shows
                // up). The presence of pending text is what signals a real
                // submission.
                if let pending = sessions[index].pendingPromptText, !pending.isEmpty {
                    if pending.trimmingCharacters(in: .whitespaces).hasPrefix("/remote-control") {
                        print("[status] skipped /remote-control exchange: \"\(pending)\"")
                        sessions[index].pendingPromptText = nil
                        return
                    }
                    // Dedupe: the prompt-input scraper can re-pick the same text
                    // from a buffer echo after a flicker (e.g. .working → .idle →
                    // .working between tool calls), which would otherwise append
                    // a phantom duplicate exchange. If the latest exchange has the
                    // identical prompt and is recent, treat the freeze as redundant.
                    let isDuplicate = sessions[index].exchanges.last.map { last in
                        last.prompt == pending && Date().timeIntervalSince(last.promptAt) < 120
                    } ?? false
                    if isDuplicate {
                        print("[status] skipped duplicate exchange freeze: \"\(pending)\"")
                        sessions[index].pendingPromptText = nil
                    } else {
                        print("[status] pushed new exchange: \"\(pending)\"")
                        // If the previous exchange never got summarized (user submitted
                        // a new prompt before .taskCompleted could fire), kick off its
                        // summary now using the buffer state from just before the new
                        // exchange starts altering it.
                        if let lastIdx = sessions[index].exchanges.indices.last,
                           sessions[index].exchanges[lastIdx].summaryStatus == .none,
                           sessions[index].exchanges[lastIdx].summary == nil {
                            let previousExchangeId = sessions[index].exchanges[lastIdx].id
                            sessions[index].exchanges[lastIdx].completedAt = Date()
                            requestSummary(for: id, exchangeId: previousExchangeId)
                        }
                        sessions[index].exchanges.append(TaskExchange(prompt: pending))
                        sessions[index].pendingPromptText = nil
                        persistSessions()
                    }
                }
            }
            if status == .waitingForInput && previous != .waitingForInput {
                playSound(named: "waitingForInput")
                if isPinned && !isTerminalExpanded && id == activeSessionId {
                    isTerminalExpanded = true
                    NotificationCenter.default.post(name: .NotchyExpandPanel, object: nil)
                }
            }
            else if status == .taskCompleted && previous != .taskCompleted {
                playSound(named: "taskCompleted")
                // A command just finished — refresh usage if our last snapshot is
                // older than a minute. The 5-min timer is the fallback; this is
                // the primary trigger so the header tracks real activity.
                UsageMonitor.shared.refreshIfStale(maxAge: 60)
                // Attach summary to the most recent exchange (the one that just finished).
                if let lastIdx = sessions[index].exchanges.indices.last {
                    let exchangeId = sessions[index].exchanges[lastIdx].id
                    sessions[index].exchanges[lastIdx].completedAt = Date()
                    persistSessions()
                    if sessions[index].exchanges[lastIdx].summaryStatus == .none {
                        requestSummary(for: id, exchangeId: exchangeId)
                    }
                }
            }
            else if status == .idle && previous == .working {
                // Delay 3s before treating as "task completed" — Claude sometimes
                // goes working → idle → working again briefly.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    guard let idx = self.sessions.firstIndex(where: { $0.id == id }),
                          self.sessions[idx].terminalStatus == .idle else { return }
                    SessionStore.shared.updateTerminalStatus(id, status: .taskCompleted)
                    // Auto-clear taskCompleted after 3 seconds
                    try? await Task.sleep(for: .seconds(3))
                    guard let idx2 = self.sessions.firstIndex(where: { $0.id == id }),
                          self.sessions[idx2].terminalStatus == .taskCompleted else { return }
                    self.sessions[idx2].terminalStatus = .idle
                    NotificationCenter.default.post(name: .NotchyNotchStatusChanged, object: nil)
                }
            }
        }
    }

    private func playSound(named name: String) {
        guard SettingsManager.shared.soundsEnabled else { return }
        if SettingsManager.shared.muteSoundsDuringCalls && MicrophoneActivityMonitor.isInputDeviceActive { return }
        let now = Date()
        guard now.timeIntervalSince(lastSoundPlayedAt) >= 1.0 else { return }
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else { return }
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
            lastSoundPlayedAt = now
        } catch {}
    }

    private func updateSleepPrevention() {
        // Only local work keeps this Mac awake — the worker holds its own assertion.
        let anyWorking = sessions.contains { !$0.isRemote && $0.terminalStatus == .working }
        if anyWorking && sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: "Claude is working"
            )
        } else if !anyWorking, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    /// Close tab: removes the session entirely and dismisses the project from auto-detection
    /// Refresh the lastCheckpoint for the active session
    func refreshLastCheckpoint() {
        guard let session = activeSession,
              let dir = session.projectPath else {
            lastCheckpoint = nil
            lastCheckpointProjectName = nil
            lastCheckpointProjectDir = nil
            return
        }
        let projectDir = (dir as NSString).deletingLastPathComponent
        let checkpoints = CheckpointManager.shared.checkpoints(for: session.projectName, in: projectDir)
        lastCheckpoint = checkpoints.first
        lastCheckpointProjectName = session.projectName
        lastCheckpointProjectDir = projectDir
    }

    /// Restore the most recent checkpoint for the active session
    func restoreLastCheckpoint() {
        guard let checkpoint = lastCheckpoint,
              let projectDir = lastCheckpointProjectDir else { return }
        checkpointStatus = "Restoring checkpoint…"
        DispatchQueue.global(qos: .userInitiated).async {
            try? CheckpointManager.shared.restoreCheckpoint(checkpoint, to: projectDir)
            DispatchQueue.main.async {
                self.checkpointStatus = nil
                self.lastCheckpoint = nil
            }
        }
    }

    /// Create a checkpoint with progress status
    func createCheckpointForActiveSession() {
        guard let session = activeSession,
              let dir = session.projectPath else { return }
        let projectDir = (dir as NSString).deletingLastPathComponent
        let projectName = session.projectName
        checkpointStatus = "Saving checkpoint…"
        DispatchQueue.global(qos: .userInitiated).async {
            try? CheckpointManager.shared.createCheckpoint(projectName: projectName, projectDirectory: projectDir)
            DispatchQueue.main.async {
                self.refreshLastCheckpoint()
                self.checkpointStatus = nil
            }
        }
    }

    /// Create a checkpoint for a specific session by ID
    func createCheckpoint(for sessionId: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionId }),
              let dir = session.projectPath else { return }
        let projectDir = (dir as NSString).deletingLastPathComponent
        let projectName = session.projectName
        checkpointStatus = "Saving checkpoint…"
        DispatchQueue.global(qos: .userInitiated).async {
            try? CheckpointManager.shared.createCheckpoint(projectName: projectName, projectDirectory: projectDir)
            DispatchQueue.main.async {
                self.refreshLastCheckpoint()
                self.checkpointStatus = nil
            }
        }
    }

    /// Sessions that have a project path (eligible for checkpoints)
    var checkpointEligibleSessions: [TerminalSession] {
        sessions.filter { $0.projectPath != nil }
    }

    /// Restore a specific checkpoint for a session
    func restoreCheckpoint(_ checkpoint: Checkpoint, for sessionId: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionId }),
              let dir = session.projectPath else { return }
        let projectDir = (dir as NSString).deletingLastPathComponent
        checkpointStatus = "Restoring checkpoint…"
        DispatchQueue.global(qos: .userInitiated).async {
            try? CheckpointManager.shared.restoreCheckpoint(checkpoint, to: projectDir)
            DispatchQueue.main.async {
                self.checkpointStatus = nil
                self.refreshLastCheckpoint()
            }
        }
    }

    func restartSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].isRemote else { return }
        TerminalManager.shared.destroyTerminal(for: id)
        sessions[index].terminalStatus = .idle
        sessions[index].generation += 1
    }

    /// Persist the current session order (used after a drag-reorder)
    func persistSessionOrder() {
        persistSessions()
    }

    func closeSession(_ id: UUID) {
        if let session = sessions.first(where: { $0.id == id }), session.isRemote {
            // Closing a remote tab only hides it locally — never a remote kill.
            hideRemoteSession(id)
            return
        }
        if let session = sessions.first(where: { $0.id == id }) {
            dismissedProjects[session.projectName] = false
        }
        TerminalManager.shared.destroyTerminal(for: id)
        sessions.removeAll { $0.id == id }
        if activeSessionId == id {
            activeSessionId = sessions.first?.id
        }
        persistSessions()
    }

    // MARK: - Remote Sessions

    private static let hiddenRemoteSessionsKey = "hiddenRemoteSessionIds"

    /// Remote session ids the user closed locally. Skipped when manifests are
    /// applied so the tab doesn't reappear on the next sync cycle. Capped so a
    /// long-lived install can't grow the blob unboundedly.
    @ObservationIgnored private lazy var hiddenRemoteSessionIds: Set<UUID> = {
        let strings = UserDefaults.standard.stringArray(forKey: Self.hiddenRemoteSessionsKey) ?? []
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }()

    func isRemoteSessionHidden(_ id: UUID) -> Bool {
        hiddenRemoteSessionIds.contains(id)
    }

    /// Hide a remote tab locally (the "close" action for remote sessions).
    func hideRemoteSession(_ id: UUID) {
        hiddenRemoteSessionIds.insert(id)
        if hiddenRemoteSessionIds.count > 200 {
            hiddenRemoteSessionIds = Set(hiddenRemoteSessionIds.prefix(200))
        }
        UserDefaults.standard.set(hiddenRemoteSessionIds.map(\.uuidString), forKey: Self.hiddenRemoteSessionsKey)
        sessions.removeAll { $0.id == id }
        RemoteTerminalManager.shared.destroyTerminal(for: id)
        if activeSessionId == id {
            activeSessionId = sessionsInActiveGroup.first?.id ?? sessions.first?.id
        }
    }

    /// Insert or refresh a proxy session mirrored from another Mac. Preserves
    /// local view state (selection, peer-online flag) and never lets an older
    /// snapshot clobber fresher live data.
    func upsertRemoteSession(_ session: TerminalSession) {
        guard session.isRemote, !hiddenRemoteSessionIds.contains(session.id) else { return }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            guard (session.remoteLastUpdated ?? .distantPast) > (sessions[index].remoteLastUpdated ?? .distantPast) else {
                // Snapshot is older than what we have — still adopt renames,
                // which don't bump the status timestamp.
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
    }

    /// Drop this machine's remote sessions that no longer exist on the worker.
    func removeRemoteSessions(for machineId: UUID, keeping ids: Set<UUID>) {
        let removed = sessions.filter { $0.originMachineId == machineId && !ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        sessions.removeAll { $0.originMachineId == machineId && !ids.contains($0.id) }
        for session in removed {
            RemoteTerminalManager.shared.destroyTerminal(for: session.id)
        }
        if let active = activeSessionId, !sessions.contains(where: { $0.id == active }) {
            activeSessionId = sessionsInActiveGroup.first?.id ?? sessions.first?.id
        }
    }

    /// Flip live-transport reachability for all of a machine's sessions.
    func setPeerOnline(_ machineId: UUID, _ online: Bool) {
        var changed = false
        for i in sessions.indices where sessions[i].originMachineId == machineId {
            if sessions[i].isPeerOnline != online {
                sessions[i].isPeerOnline = online
                changed = true
            }
        }
        if changed {
            NotificationCenter.default.post(name: .NotchyNotchStatusChanged, object: nil)
        }
    }

    /// Apply a status update that arrived pre-digested from the session's
    /// worker Mac. Fields are written verbatim and the user-facing reactions
    /// fire (sound, notch refresh) — but NONE of the scraper-derived side
    /// effects: no exchange freezing (exchanges sync from the worker), no
    /// summarization, no sleep prevention, no taskCompleted timers.
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
              sessions[index].isRemote,
              timestamp >= (sessions[index].remoteLastUpdated ?? .distantPast) else { return }
        let previous = sessions[index].terminalStatus
        sessions[index].terminalStatus = status
        sessions[index].activityLine = activityLine
        sessions[index].pendingPromptText = pendingPromptText
        sessions[index].pendingChoices = pendingChoices
        sessions[index].pendingQuestion = pendingQuestion
        sessions[index].pendingPromptPreview = pendingPromptPreview
        if let exchanges { sessions[index].exchanges = exchanges }
        sessions[index].remoteLastUpdated = timestamp
        if status == .working {
            if sessions[index].workingStartedAt == nil {
                sessions[index].workingStartedAt = Date()
            }
        } else {
            sessions[index].workingStartedAt = nil
        }

        guard status != previous else { return }
        NotificationCenter.default.post(name: .NotchyNotchStatusChanged, object: nil)
        // Only live peers make noise — a stale snapshot replaying an old
        // transition shouldn't chime.
        if sessions[index].isPeerOnline {
            if status == .waitingForInput {
                playSound(named: "waitingForInput")
            } else if status == .taskCompleted {
                playSound(named: "taskCompleted")
            }
        }
    }

    /// Find or create the synthetic group that holds a remote machine's tabs.
    func findOrCreateRemoteGroup(machineId: UUID, name: String) -> UUID {
        if let index = projectGroups.firstIndex(where: { $0.remoteMachineId == machineId }) {
            if projectGroups[index].name != name {
                projectGroups[index].name = name
            }
            return projectGroups[index].id
        }
        let group = ProjectGroup(name: name, remoteMachineId: machineId)
        projectGroups.append(group)
        return group.id
    }

    /// Remove every remote session and synthetic group — used when the user
    /// turns the remote-tabs feature off.
    func removeAllRemoteState() {
        for session in sessions where session.isRemote {
            RemoteTerminalManager.shared.destroyTerminal(for: session.id)
        }
        sessions.removeAll { $0.isRemote }
        projectGroups.removeAll { $0.remoteMachineId != nil }
        if let activeGroup = activeProjectGroupId,
           !projectGroups.contains(where: { $0.id == activeGroup }) {
            activeProjectGroupId = projectGroups.first?.id
        }
        if let active = activeSessionId, !sessions.contains(where: { $0.id == active }) {
            activeSessionId = sessionsInActiveGroup.first?.id ?? sessions.first?.id
        }
    }
}
