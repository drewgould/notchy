import Foundation

nonisolated enum TerminalStatus: String, Equatable, Codable {
    /// Default — no special activity detected
    case idle
    /// Claude is working (status line matches token counter pattern)
    case working
    /// Claude is waiting for user input ("Esc to cancel")
    case waitingForInput
    /// Claude was interrupted by the user (Esc pressed)
    case interrupted
    /// Claude finished a task (confirmed via idle timer line after working)
    case taskCompleted
}

nonisolated enum SummaryStatus: String, Equatable, Codable {
    case none
    case generating
    case ready
    case failed
}

/// One prompt-and-response cycle inside a session: the request the user
/// submitted, an LLM-generated summary of what Claude did, and whether the
/// user has ticked off the work as verified.
nonisolated struct TaskExchange: Identifiable, Equatable, Codable {
    let id: UUID
    let prompt: String
    let promptAt: Date
    var completedAt: Date?
    var summary: String?
    var summaryStatus: SummaryStatus
    var verified: Bool
    /// True when the user pressed Esc during this exchange. Renders an orange
    /// "!" badge in place of the verified checkbox.
    var wasInterrupted: Bool

    init(prompt: String, promptAt: Date = Date()) {
        self.id = UUID()
        self.prompt = prompt
        self.promptAt = promptAt
        self.completedAt = nil
        self.summary = nil
        self.summaryStatus = .none
        self.verified = false
        self.wasInterrupted = false
    }

    enum CodingKeys: String, CodingKey {
        case id, prompt, promptAt, completedAt, summary, summaryStatus, verified, wasInterrupted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.prompt = try c.decode(String.self, forKey: .prompt)
        self.promptAt = try c.decode(Date.self, forKey: .promptAt)
        self.completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
        self.summaryStatus = try c.decodeIfPresent(SummaryStatus.self, forKey: .summaryStatus) ?? .none
        self.verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        self.wasInterrupted = try c.decodeIfPresent(Bool.self, forKey: .wasInterrupted) ?? false
    }
}

/// A numbered choice extracted from Claude's interactive prompt
/// (e.g. "❯ 1. Yes", "  2. No"). `isSelected` reflects which option
/// Claude's UI has highlighted with the ❯ arrow.
nonisolated struct PromptChoice: Equatable, Identifiable, Codable {
    var id: Int { number }
    let number: Int
    let label: String
    let isSelected: Bool
}

struct TerminalSession: Identifiable {
    let id: UUID
    var projectName: String
    var projectPath: String?
    var workingDirectory: String
    var hasStarted: Bool
    var terminalStatus: TerminalStatus
    var generation: Int
    /// Whether the user has ever manually selected this tab
    var hasBeenSelected: Bool
    let createdAt: Date
    /// When the session most recently entered the .working state
    var workingStartedAt: Date?
    /// Continuously-updated snapshot of what the user is currently typing in Claude's prompt box
    var pendingPromptText: String?
    /// Ordered prompt/response history for this session. New exchanges are pushed
    /// on the .working transition (when the user submits a prompt) and get their
    /// summary filled in when the task completes.
    var exchanges: [TaskExchange]
    /// Live activity/spinner line scraped from the terminal while Claude is working
    /// (e.g. "✻ Brewing… (3s · ↑ 1.2k tokens · esc to interrupt)")
    var activityLine: String?
    /// Numbered choices Claude is currently offering (only populated in .waitingForInput)
    var pendingChoices: [PromptChoice]
    /// The question line above the numbered choices (e.g. "Do you want to proceed?").
    /// Only populated in .waitingForInput.
    var pendingQuestion: String?
    /// Preview content above the question — typically a diff/file header for edit
    /// confirmations, or the body of a `WebFetch` / `Bash` command preview. Lines
    /// are joined with `\n`. Only populated in .waitingForInput.
    var pendingPromptPreview: String?
    /// Project group this session belongs to. nil during migration / before
    /// auto-assignment runs; SessionStore resolves it to a real group on first
    /// touch via the session's git root.
    var groupId: UUID?

    // MARK: Remote-tab support

    /// Machine that owns the real terminal. nil = this Mac (local session).
    var originMachineId: UUID? = nil
    /// Display name of the origin machine, for badges and placeholders.
    var originMachineName: String? = nil
    /// Live-transport reachability of the origin machine. Meaningless for local sessions.
    var isPeerOnline: Bool = false
    /// Timestamp of the newest remote data applied to this session. Live network
    /// updates stamp `Date()`; iCloud snapshots carry the worker's `updatedAt` —
    /// an older snapshot must never clobber fresher network state.
    var remoteLastUpdated: Date? = nil

    /// True when the real terminal lives on another Mac.
    var isRemote: Bool { originMachineId != nil }
    /// Remote tab whose peer is unreachable — render grayed, status is last-known.
    var isStale: Bool { isRemote && !isPeerOnline }
    /// Sessions whose status should drive notch/sound/attention aggregates.
    var isStatusLive: Bool { !isRemote || isPeerOnline }

    /// Convenience: the prompt of the most recent exchange (for the panel "Last request" bar).
    var lastRequest: String? { exchanges.last?.prompt }

    init(projectName: String, projectPath: String? = nil, workingDirectory: String? = nil, started: Bool = false, groupId: UUID? = nil) {
        self.id = UUID()
        self.projectName = projectName
        self.projectPath = projectPath
        self.workingDirectory = workingDirectory ?? projectPath ?? NSHomeDirectory()
        self.hasStarted = started
        self.terminalStatus = .idle
        self.generation = 0
        self.hasBeenSelected = started // if started immediately (e.g. "+" button), mark as selected
        self.createdAt = Date()
        self.exchanges = []
        self.activityLine = nil
        self.pendingChoices = []
        self.pendingQuestion = nil
        self.pendingPromptPreview = nil
        self.groupId = groupId
    }

    /// Restore a session from persisted data
    init(persisted: PersistedSession) {
        self.id = persisted.id
        self.projectName = persisted.projectName
        // Migrate sessions persisted by older builds where AppleScript's
        // `missing value` leaked through as a literal path string.
        let projectPath: String? = {
            guard let p = persisted.projectPath, !p.isEmpty, p != "missing value" else { return nil }
            return p
        }()
        self.projectPath = projectPath
        // The project's containing directory (projectPath points at the
        // .xcodeproj/.xcworkspace itself, so cd one level up).
        let projectDir: String? = projectPath.flatMap { p in
            let dir = (p as NSString).deletingLastPathComponent
            return FileManager.default.fileExists(atPath: dir) ? dir : nil
        }
        // Fall back if the persisted directory is empty, no longer exists, or is
        // "/" — a failed chdir leaves the shell in the app's own cwd (root),
        // which OSC 7 then persisted; no real session lives at root.
        var dir = persisted.workingDirectory
        if dir.isEmpty || dir == "/" || !FileManager.default.fileExists(atPath: dir) {
            dir = projectDir ?? NSHomeDirectory()
        }
        self.workingDirectory = dir
        self.hasStarted = false
        self.terminalStatus = .idle
        self.generation = 0
        self.hasBeenSelected = false
        self.createdAt = Date()
        // Demote any in-flight summaries to .failed — we can't resume the API
        // call across launches, and the terminal buffer that fed it is gone.
        self.exchanges = persisted.exchanges.map { exchange in
            var e = exchange
            if e.summaryStatus == .generating {
                e.summaryStatus = e.summary == nil ? .failed : .ready
            }
            return e
        }
        self.activityLine = nil
        self.pendingChoices = []
        self.pendingQuestion = nil
        self.pendingPromptPreview = nil
        self.pendingPromptText = persisted.pendingPromptText
        self.groupId = persisted.groupId
    }

    /// Build a proxy session for a tab that lives on another Mac.
    /// `projectPath` stays nil deliberately — every checkpoint path guards on
    /// it, so remote sessions are naturally inert there. `hasStarted` stays
    /// false so no local terminal ever spawns.
    init(snapshot: SessionSnapshot, machineId: UUID, machineName: String, groupId: UUID) {
        self.id = snapshot.id
        self.projectName = snapshot.projectName
        self.projectPath = nil
        self.workingDirectory = snapshot.workingDirectory
        self.hasStarted = false
        self.terminalStatus = snapshot.status
        self.generation = 0
        self.hasBeenSelected = false
        self.createdAt = Date()
        self.workingStartedAt = nil
        self.exchanges = snapshot.exchanges
        self.activityLine = snapshot.activityLine
        self.pendingChoices = []
        self.pendingQuestion = snapshot.pendingQuestion
        self.pendingPromptPreview = nil
        self.pendingPromptText = nil
        self.groupId = groupId
        self.originMachineId = machineId
        self.originMachineName = machineName
        self.isPeerOnline = false
        self.remoteLastUpdated = snapshot.updatedAt
    }
}

/// Lightweight Codable representation for UserDefaults persistence
struct PersistedSession: Codable {
    let id: UUID
    let projectName: String
    let projectPath: String?
    let workingDirectory: String
    var exchanges: [TaskExchange] = []
    /// Draft text the user was composing in Claude's input box at quit time.
    /// Live status / choices / spinner aren't saved — they describe a dead claude process.
    var pendingPromptText: String?
    /// Group membership. nil for pre-grouping sessions; resolved on first load.
    var groupId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, projectName, projectPath, workingDirectory, exchanges, pendingPromptText, groupId
    }

    init(id: UUID, projectName: String, projectPath: String?, workingDirectory: String, exchanges: [TaskExchange], pendingPromptText: String?, groupId: UUID?) {
        self.id = id
        self.projectName = projectName
        self.projectPath = projectPath
        self.workingDirectory = workingDirectory
        self.exchanges = exchanges
        self.pendingPromptText = pendingPromptText
        self.groupId = groupId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.projectName = try c.decode(String.self, forKey: .projectName)
        self.projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        self.workingDirectory = try c.decode(String.self, forKey: .workingDirectory)
        self.exchanges = (try? c.decode([TaskExchange].self, forKey: .exchanges)) ?? []
        self.pendingPromptText = try? c.decodeIfPresent(String.self, forKey: .pendingPromptText)
        self.groupId = try? c.decodeIfPresent(UUID.self, forKey: .groupId)
    }
}
