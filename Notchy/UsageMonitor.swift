import AppKit
import OSLog
import SwiftTerm

private let usageLog = Logger(subsystem: "com.notchy.app", category: "UsageMonitor")

/// A parsed slice of `/usage` output for one window (5-hour, weekly, weekly Opus, etc).
struct UsageWindow: Identifiable, Equatable, Codable {
    var id: String { label }
    let label: String
    let percent: Int
    let resets: String?
}

/// A parsed `/usage` snapshot.
struct UsageSnapshot: Equatable, Codable {
    let fetchedAt: Date
    let plan: String?
    let windows: [UsageWindow]
    /// Full raw text we scraped — kept so the UI can show something even if parsing misses fields.
    let raw: String
}

/// Polls Claude Code's `/usage` command via a long-lived hidden `claude` PTY,
/// then parses the rendered panel into a structured snapshot for the Conductor.
///
/// Long-lived (vs spawn-per-poll) because cold-starting `claude` takes 3–5s
/// and is heavy. Once spawned, we just send `/usage`, wait, scrape, send ESC.
@Observable
@MainActor
final class UsageMonitor {
    static let shared = UsageMonitor()

    private(set) var snapshot: UsageSnapshot?
    private(set) var isRefreshing: Bool = false
    private(set) var lastError: String?

    private static let refreshInterval: TimeInterval = 300
    /// Hard timeout for an in-flight refresh. If `refreshInProgress` has been
    /// stuck longer than this (e.g. scrape closure short-circuited because the
    /// hidden terminal got deallocated), force-clear it so subsequent calls
    /// aren't permanently skipped.
    private static let refreshStuckTimeout: TimeInterval = 30
    /// Initial delay before the first scrape attempt — gives claude time to
    /// render the /usage panel frame (tabs + "Loading usage data…" placeholder).
    private static let initialScrapeDelay: TimeInterval = 1.5
    /// Interval between subsequent re-scrape attempts while we wait for
    /// "Loading usage data…" to be replaced by real percentages.
    private static let pollInterval: TimeInterval = 0.5
    /// Maximum total time to wait for the panel to populate before giving up.
    private static let scrapeBudget: TimeInterval = 10.0
    /// How long after spawn before claude has likely rendered something.
    private static let warmupDelay: TimeInterval = 4.0
    /// How long after accepting trust before claude's main prompt is usable.
    private static let postTrustDelay: TimeInterval = 3.0
    private static let snapshotKey = "usageSnapshot"

    private enum BootstrapState {
        case notStarted
        case spawning
        case acceptingTrust
        case ready
    }

    private var terminal: HiddenTerminal?
    private var refreshTimer: Timer?
    private var bootstrapState: BootstrapState = .notStarted
    /// Suppresses concurrent refreshes when one is already in flight.
    private var refreshInProgress = false
    /// Wall-clock time the in-flight refresh started — used to detect a stuck flag.
    private var refreshStartedAt: Date?

    private init() {
        // Restore the last snapshot so the Conductor's usage header has data
        // immediately on launch instead of being blank for the ~6s warmup.
        if let data = UserDefaults.standard.data(forKey: Self.snapshotKey),
           let restored = try? JSONDecoder().decode(UsageSnapshot.self, from: data) {
            self.snapshot = restored
        }
    }

    func start() {
        guard bootstrapState == .notStarted else { return }
        usageLog.info("start() — spawning hidden claude")
        bootstrapState = .spawning
        spawnTerminalIfNeeded()

        // After warmup, accept the workspace-trust prompt (Enter selects the
        // default "Yes, I trust" option). If claude is already past the trust
        // prompt for some reason, Enter at the main input box is harmless.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.warmupDelay) { [weak self] in
            guard let self, let term = self.terminal else { return }
            let preTrust = term.scrapeBuffer()
            usageLog.info("post-warmup scrape (first 300 chars): \(preTrust.prefix(300), privacy: .public)")
            self.bootstrapState = .acceptingTrust
            usageLog.info("sending Enter to accept trust prompt")
            term.send(text: "\r")

            // Give claude a moment to render its main prompt, then begin polling.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.postTrustDelay) { [weak self] in
                guard let self else { return }
                self.bootstrapState = .ready
                usageLog.info("bootstrap complete — beginning /usage polling")
                self.refreshNow()
                self.refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.refreshNow() }
                }
            }
        }
    }

    /// Refresh only if no snapshot or the current snapshot is older than `maxAge`.
    /// Called after each completed task so usage stays current without hammering /usage
    /// when several sessions finish in quick succession.
    func refreshIfStale(maxAge: TimeInterval) {
        if let fetched = snapshot?.fetchedAt, Date().timeIntervalSince(fetched) < maxAge {
            return
        }
        refreshNow()
    }

    func refreshNow() {
        if refreshInProgress {
            if let started = refreshStartedAt, Date().timeIntervalSince(started) > Self.refreshStuckTimeout {
                usageLog.warning("refresh appeared stuck for >\(Self.refreshStuckTimeout, privacy: .public)s — clearing flag and retrying")
                refreshInProgress = false
                refreshStartedAt = nil
                isRefreshing = false
            } else {
                usageLog.debug("refreshNow skipped — already in flight")
                return
            }
        }
        guard bootstrapState == .ready else {
            usageLog.debug("refreshNow skipped — bootstrap not ready (state=\(String(describing: self.bootstrapState), privacy: .public))")
            return
        }
        guard let term = terminal else {
            usageLog.warning("refreshNow with nil terminal — respawning")
            spawnTerminalIfNeeded()
            return
        }

        // If claude exited (e.g. user/system killed it), the scrape buffer will
        // show a zsh prompt. Detect and respawn instead of typing /usage into the shell.
        let preCheck = term.scrapeBuffer()
        if preCheck.contains("zsh:") || preCheck.range(of: #"% $"#, options: .regularExpression) != nil {
            usageLog.warning("detected zsh prompt in buffer — claude has exited, respawning")
            terminal = nil
            bootstrapState = .notStarted
            refreshTimer?.invalidate()
            refreshTimer = nil
            start()
            return
        }

        refreshInProgress = true
        refreshStartedAt = Date()
        isRefreshing = true
        usageLog.info("sending /usage")
        term.send(text: "/usage\r")

        let started = Date()
        scrapeWhenReady(term: term, startedAt: started, delay: Self.initialScrapeDelay)
    }

    /// Resets in-flight tracking so the next refresh isn't suppressed. Called
    /// from every exit path of `scrapeWhenReady`, including the weak-ref no-op.
    private func finishRefresh() {
        isRefreshing = false
        refreshInProgress = false
        refreshStartedAt = nil
    }

    /// Polls the /usage buffer until it actually contains percentage data
    /// (claude renders "Loading usage data…" first and fills in numbers a
    /// beat later). Falls back to whatever's there when the budget expires.
    private func scrapeWhenReady(term: HiddenTerminal, startedAt: Date, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak term] in
            guard let self else { return }
            guard let term else {
                usageLog.warning("scrapeWhenReady: hidden terminal deallocated mid-refresh — clearing flag")
                self.finishRefresh()
                return
            }
            let raw = term.scrapeBuffer()
            let elapsed = Date().timeIntervalSince(startedAt)
            let elapsedStr = String(format: "%.1f", elapsed)
            let hasUsageData = raw.range(of: #"\d+%\s+used"#, options: .regularExpression) != nil
            let stillLoading = raw.contains("Loading usage data")

            if !hasUsageData && stillLoading && elapsed < Self.scrapeBudget {
                usageLog.debug("usage still loading at \(elapsedStr, privacy: .public)s, re-polling")
                self.scrapeWhenReady(term: term, startedAt: startedAt, delay: Self.pollInterval)
                return
            }

            let parsed = Self.parse(raw: raw)
            usageLog.info("scraped /usage — plan=\(parsed.plan ?? "nil", privacy: .public) windows=\(parsed.windows.count) elapsed=\(elapsedStr, privacy: .public)s")
            Self.appendDebugLog(raw: raw, parsed: parsed)
            if !parsed.windows.isEmpty || parsed.plan != nil {
                self.snapshot = parsed
                if let data = try? JSONEncoder().encode(parsed) {
                    UserDefaults.standard.set(data, forKey: Self.snapshotKey)
                }
                self.lastError = nil
            } else if self.snapshot == nil {
                self.lastError = "No /usage output parsed (claude may still be loading)."
                usageLog.warning("no usage data parsed and no prior snapshot")
            }
            self.finishRefresh()
            // Dismiss the /usage panel so it's not in the way on the next poll.
            // Safe now because we know claude is past the trust prompt.
            term.send(text: "\u{1B}")
        }
    }

    /// Writes each scrape to `~/Library/Logs/Notchy/usage-raw.log` so we can
    /// see what `/usage` actually renders and tune the parser against it.
    private static func appendDebugLog(raw: String, parsed: UsageSnapshot) {
        let fm = FileManager.default
        guard let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Notchy", isDirectory: true) else { return }
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logURL = logsDir.appendingPathComponent("usage-raw.log")

        let ts = ISO8601DateFormatter().string(from: Date())
        var block = "\n===== /usage scrape @ \(ts) =====\n"
        block += "parsed: plan=\(parsed.plan ?? "nil") windows=\(parsed.windows.count)\n"
        for w in parsed.windows {
            block += "  • \(w.label) — \(w.percent)% \(w.resets ?? "")\n"
        }
        block += "----- raw buffer -----\n"
        block += raw
        block += "\n----- end -----\n"

        if let data = block.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private func spawnTerminalIfNeeded() {
        guard terminal == nil else { return }
        usageLog.info("spawning HiddenTerminal")
        terminal = HiddenTerminal()
    }

    // MARK: - Parsing

    /// Pull plan/percentages/reset info out of `/usage` text. Loose by design —
    /// the exact format isn't documented and may shift across Claude Code versions.
    static func parse(raw: String) -> UsageSnapshot {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }

        // Plan: look for a line that says "Plan", "Subscription", "Current plan", or
        // mentions a tier ("Max", "Pro").
        var plan: String?
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            let lower = t.lowercased()
            if lower.contains("plan:") || lower.contains("subscription") || lower.contains("current plan") {
                plan = t
                break
            }
        }
        if plan == nil {
            for line in lines.prefix(20) {
                let t = line.trimmingCharacters(in: .whitespaces)
                let lower = t.lowercased()
                if (lower.contains("max ") || lower.hasPrefix("max(") || lower.contains("pro plan") || lower.contains("pro ")) && t.count < 80 {
                    plan = t
                    break
                }
            }
        }

        // Windows: only lines that read "N% used" — the canonical usage-row format.
        // This filters out footnote percentages like "70% of your usage was at >150k context".
        var windows: [UsageWindow] = []
        for (i, line) in lines.enumerated() {
            guard let percent = percentUsed(in: line) else { continue }
            let label = walkUpwardForLabel(at: i, in: lines)
            let resets = nearbyReset(around: i, in: lines)
            if !windows.contains(where: { $0.label == label && $0.percent == percent }) {
                windows.append(UsageWindow(label: label, percent: percent, resets: resets))
            }
        }

        return UsageSnapshot(fetchedAt: Date(), plan: plan, windows: windows, raw: raw)
    }

    /// Matches the canonical "N% used" cell that ends every real usage row.
    private static func percentUsed(in line: String) -> Int? {
        guard let range = line.range(of: #"(\d+)%\s+used"#, options: .regularExpression) else { return nil }
        let digits = line[range].prefix(while: { $0.isNumber })
        return Int(digits)
    }

    /// Walks upward from a percent line looking for the header line above it,
    /// skipping blanks, bar-glyph rows, and decoration. Falls back to "Usage".
    private static func walkUpwardForLabel(at index: Int, in lines: [String]) -> String {
        var k = index - 1
        while k >= 0 {
            let t = lines[k].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { k -= 1; continue }
            // Skip rows that are mostly progress-bar / box-drawing glyphs with no real text.
            let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            if letters < 3 { k -= 1; continue }
            if percentUsed(in: t) != nil { k -= 1; continue }
            return String(t.prefix(60))
        }
        return "Usage"
    }

    private static func nearbyReset(around index: Int, in lines: [String]) -> String? {
        // The "Resets ..." line for a usage row is always on the line directly below.
        for offset in 1...2 {
            let i = index + offset
            guard i < lines.count else { break }
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t.lowercased().hasPrefix("resets") else { continue }
            let after = t.dropFirst("resets".count).trimmingCharacters(in: .whitespaces)
            return after.isEmpty ? nil : "resets " + after.prefix(60)
        }
        return nil
    }
}

// MARK: - Hidden terminal

/// Owns a hidden `LocalProcessTerminalView` running `claude` so we can
/// scrape `/usage` output without disturbing user-visible sessions.
@MainActor
private final class HiddenTerminal {
    private let view: ProbeTerminalView
    /// Holds the terminal in an offscreen window so it has a window context (some
    /// AppKit interactions get cranky without one). Window is never displayed.
    private let window: NSWindow

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        view = ProbeTerminalView(frame: frame)
        view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = view
        window.isReleasedWhenClosed = false
        // Position offscreen and never show.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let envArray = env.map { "\($0.key)=\($0.value)" }

        view.startProcess(
            executable: shell,
            args: ["--login"],
            environment: envArray,
            execName: "-" + (shell as NSString).lastPathComponent
        )
        // cd home first so we have a neutral cwd, then launch claude.
        view.send(txt: "cd ~ && clear && claude\r")
    }

    func send(text: String) {
        view.send(txt: text)
    }

    /// Reads the terminal buffer into plain text (one string per row).
    func scrapeBuffer() -> String {
        let terminal = view.getTerminal()
        guard terminal.rows > 0 else { return "" }
        var lines: [String] = []
        for row in 0..<terminal.rows {
            var line = ""
            for col in 0..<terminal.cols {
                let ch = terminal.getCharacter(col: col, row: row) ?? " "
                line.append(ch == "\u{0}" ? " " : ch)
            }
            // Trim trailing spaces but keep leading indentation (preserves label/value alignment).
            while let last = line.last, last == " " { line.removeLast() }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// Minimal LocalProcessTerminalView subclass — no delegate / no extra UI; we
/// only ever read the buffer, never display or interact with it from the UI.
private final class ProbeTerminalView: LocalProcessTerminalView {}
