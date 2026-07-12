import AppKit
import SwiftTerm

class ClickThroughTerminalView: LocalProcessTerminalView {
    var sessionId: UUID?
    private var keyMonitor: Any?
    // Held until the shell signals readiness (first OSC 7 cwd report = first
    // prompt drawn). Sending input right after startProcess races login-shell
    // init, which can flush the tty input queue and silently drop the command.
    private var pendingStartupCommand: String?
    private var statusDebounceWork: DispatchWorkItem?
    private static let statusQueue = DispatchQueue(label: "com.notchy.status", qos: .utility)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        installArrowKeyMonitor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        installArrowKeyMonitor()
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Intercept arrow key events locally and send standard VT100/xterm sequences
    /// to avoid kitty keyboard protocol (CSI u) encoding issues.
    private func installArrowKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.firstResponder === self else { return event }

            let arrowCode: String?
            switch event.keyCode {
            case 126: arrowCode = "A" // Up
            case 125: arrowCode = "B" // Down
            case 124: arrowCode = "C" // Right
            case 123: arrowCode = "D" // Left
            default: arrowCode = nil
            }

            guard let code = arrowCode else { return event }

            let mods = event.modifierFlags.intersection([.shift, .option, .control])
            if mods.isEmpty {
                self.send(txt: "\u{1b}[\(code)")
            } else {
                var modifier = 1
                if mods.contains(.shift) { modifier += 1 }
                if mods.contains(.option) { modifier += 2 }
                if mods.contains(.control) { modifier += 4 }
                self.send(txt: "\u{1b}[1;\(modifier)\(code)")
            }
            return nil // consume the event
        }
    }

    /// Queues a command to send once the shell is ready, with a timer fallback
    /// for shells that never emit OSC 7 (e.g. bash without the Apple_Terminal rc).
    func queueStartupCommand(_ text: String, fallbackAfter seconds: TimeInterval) {
        pendingStartupCommand = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.flushPendingStartupCommand()
        }
    }

    /// Sends the queued startup command if one is still pending. Must be called
    /// on the main thread; idempotent so the OSC 7 trigger and the fallback
    /// timer can both fire.
    func flushPendingStartupCommand() {
        guard let command = pendingStartupCommand else { return }
        pendingStartupCommand = nil
        send(txt: command)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return false
        }
        let paths = items.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        send(txt: paths)
        return true
    }

    /// Returns all visible lines from the terminal buffer.
    ///
    /// SwiftTerm's `Terminal`/`Buffer` is NOT thread-safe. Reading the buffer
    /// off the main thread races with main-thread reflow/resize mutations and
    /// corrupts the buffer's array storage — a SIGABRT crash ("object
    /// deallocated with non-zero retain count"). So the actual buffer read is
    /// always marshalled onto the main thread; callers may invoke this from any
    /// queue and get back a plain `[String]` snapshot they can parse anywhere.
    func extractAllLines() -> [String]? {
        if Thread.isMainThread {
            return extractAllLinesOnMain()
        }
        return DispatchQueue.main.sync { extractAllLinesOnMain() }
    }

    private func extractAllLinesOnMain() -> [String]? {
        let terminal = getTerminal()
        guard terminal.rows >= 20 else { return nil }
        var lineTexts: [String] = []
        for row in 0..<terminal.rows {
            var line = ""
            for col in 0..<terminal.cols {
                let ch = terminal.getCharacter(col: col, row: row) ?? " "
                line.append(ch == "\u{0}" ? " " : ch)
            }
            lineTexts.append(line)
        }
        return lineTexts
    }

    /// Returns the last 20 non-blank lines from the given lines, joined by newlines.
    private func relevantText(from lines: [String]) -> String {
        let nonBlankLines = lines.filter { !$0.allSatisfy({ $0 == " " }) }
        return nonBlankLines.suffix(20).joined(separator: "\n")
    }

    /// Returns the last 20 non-blank lines of terminal output above the prompt separator.
    func extractVisibleText(from lines: [String]) -> String? {
        var lineTexts = lines

        // Find the last horizontal rule separator (────...) which divides
        // Claude's output from the user's current prompt input area.
        // Only consider text above it so we don't capture the in-progress prompt.
        // Exclude box-corner lines (╭───╮ / ╰───╯) since the top of the input box
        // also contains long runs of ─ and would otherwise be matched first.
        if let lastSeparatorIndex = lineTexts.lastIndex(where: Self.isPlainHorizontalRule) {
            lineTexts = Array(lineTexts.prefix(lastSeparatorIndex))
        }

        return relevantText(from: lineTexts)
    }

    private static func isPlainHorizontalRule(_ line: String) -> Bool {
        guard line.contains("────────") else { return false }
        for ch in line {
            if "╭╮╰╯│".contains(ch) { return false }
        }
        return true
    }

    /// Returns the last 20 non-blank lines of the full terminal output (including prompt area).
    func extractFullVisibleText(from lines: [String]) -> String? {
        return relevantText(from: lines)
    }

    /// Extracts Claude's numbered prompt choices, the question text immediately
    /// above them (e.g. "Do you want to proceed?"), and any preview block above
    /// the question (e.g. a diff for an edit confirmation). Returns empty choices
    /// / nil question / nil preview when no numbered prompt is visible.
    func extractPromptBlock(from lines: [String]) -> (choices: [PromptChoice], question: String?, preview: String?) {
        return Self.parsePromptBlock(from: lines)
    }

    fileprivate static func parsePromptBlock(from lines: [String]) -> (choices: [PromptChoice], question: String?, preview: String?) {
        func match(_ line: String) -> (isSelected: Bool, number: Int, label: String)? {
            var trimmed = Substring(line).drop(while: { $0 == " " })
            // Some prompts wrap each line in a box: "│  ❯ 1. Yes    │"
            if trimmed.hasPrefix("│") {
                trimmed = trimmed.dropFirst().drop(while: { $0 == " " })
            }
            let isSelected = trimmed.hasPrefix("❯ ")
            if isSelected { trimmed = trimmed.dropFirst(2).drop(while: { $0 == " " }) }
            let digits = trimmed.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, let number = Int(digits) else { return nil }
            var rest = trimmed.dropFirst(digits.count)
            guard rest.first == "." else { return nil }
            rest = rest.dropFirst()
            guard rest.first == " " else { return nil }
            var label = String(rest.dropFirst())
            if label.hasSuffix("│") { label = String(label.dropLast()) }
            label = label.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { return nil }
            return (isSelected, number, label)
        }

        // Lines that definitively end the option block — separators, input box
        // borders, or the input prompt arrow itself. AskUserQuestion options can
        // include indented description text between numbered items, so we can't
        // stop on "first non-matching line".
        func isBoundary(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            if isPlainHorizontalRule(line) { return true }
            if trimmed.hasPrefix("╭") || trimmed.hasPrefix("╰") { return true }
            // `❯ ` lines that aren't numbered choices are the input prompt area.
            if trimmed.hasPrefix("❯ "), match(line) == nil { return true }
            return false
        }

        // Anchor on the last selection arrow — that's the bottom of the active prompt.
        guard let anchor = lines.lastIndex(where: { match($0)?.isSelected == true }) else {
            return ([], nil, nil)
        }

        var collected: [(idx: Int, choice: PromptChoice)] = []
        var seen = Set<Int>()
        // Allow up to this many consecutive non-matching, non-boundary lines
        // (option descriptions, wrapped text) before giving up on the option block.
        let maxGap = 4

        // Walk downward from the anchor.
        var i = anchor
        var gap = 0
        while i < lines.count {
            if isBoundary(lines[i]) { break }
            if let m = match(lines[i]) {
                if seen.insert(m.number).inserted {
                    collected.append((i, PromptChoice(number: m.number, label: m.label, isSelected: m.isSelected)))
                }
                gap = 0
            } else {
                gap += 1
                if gap > maxGap { break }
            }
            i += 1
        }

        // Walk upward.
        var j = anchor - 1
        var topChoiceIdx = anchor
        gap = 0
        while j >= 0 {
            if isBoundary(lines[j]) { break }
            if let m = match(lines[j]) {
                if seen.insert(m.number).inserted {
                    collected.append((j, PromptChoice(number: m.number, label: m.label, isSelected: m.isSelected)))
                }
                topChoiceIdx = j
                gap = 0
            } else {
                gap += 1
                if gap > maxGap { break }
            }
            j -= 1
        }

        // Guard against scrollback false positives. When you answer a numbered
        // prompt with a message that itself starts with "N. " (e.g. "2. remove
        // it now"), Claude echoes it into the transcript as `❯ 2. remove it now`
        // — byte-identical to a live selected choice line. Left unchecked, that
        // stale echo anchors here, the caller skips its .idle demotion, and the
        // session stays pinned to .waitingForInput (the ⚠️ attention flag) long
        // after Claude went idle. A REAL Claude prompt is always drawn inside a
        // rounded box (│ borders, ╭/╰ corners); a transcript echo has none. So
        // require box-drawing context around the choice block, or reject it.
        let blockIndices = collected.map { $0.idx }
        guard let lo = blockIndices.min(), let hi = blockIndices.max() else {
            return ([], nil, nil)
        }
        let scanLo = max(0, lo - 2)
        let scanHi = min(lines.count - 1, hi + 2)
        let isBoxed = (scanLo...scanHi).contains { idx in
            lines[idx].contains(where: { "│╭╮╰╯".contains($0) })
        }
        guard isBoxed else { return ([], nil, nil) }

        let sortedChoices = collected.sorted { $0.choice.number < $1.choice.number }.map { $0.choice }
        let (question, questionIdx) = extractQuestion(from: lines, aboveLineIndex: topChoiceIdx)
        let preview = questionIdx.flatMap { extractPreview(from: lines, aboveQuestionAt: $0) }
        return (sortedChoices, question, preview)
    }

    /// Finds the question line (e.g. "Do you want to proceed?") that appears
    /// immediately above the numbered choices. Walks upward from `aboveLineIndex`,
    /// stripping box borders, skipping blank lines, and returns the first
    /// non-empty content line along with its index. Returns (nil, nil) if a
    /// structural boundary (top box border or horizontal rule) is hit before
    /// any text is found.
    fileprivate static func extractQuestion(from lines: [String], aboveLineIndex: Int) -> (text: String?, index: Int?) {
        var k = aboveLineIndex - 1
        while k >= 0 {
            let raw = lines[k]
            // Strip leading whitespace and `│` border on either side.
            var t = String(raw.drop(while: { $0 == " " }))
            if t.hasPrefix("│") { t = String(t.dropFirst()) }
            if t.hasSuffix("│") { t = String(t.dropLast()) }
            t = t.trimmingCharacters(in: .whitespaces)

            if t.isEmpty { k -= 1; continue }
            // Structural boundaries — we've walked out of the prompt block.
            if t.hasPrefix("╭") || t.hasPrefix("╰") { return (nil, nil) }
            if isPlainHorizontalRule(raw) { return (nil, nil) }
            return (t, k)
        }
        return (nil, nil)
    }

    /// Captures the preview content above the question — typically a diff for
    /// an edit confirmation, or the command/url body for tool-use prompts.
    /// Walks past the rule separator below the preview, then up through content
    /// lines (treating intra-preview rules as separators) until a structural
    /// boundary or the line cap is hit. Returns nil when no preview exists.
    fileprivate static func extractPreview(from lines: [String], aboveQuestionAt: Int) -> String? {
        var k = aboveQuestionAt - 1
        var crossedRule = false
        // Walk up through blank lines and a single rule separator to enter the preview region.
        while k >= 0 {
            let raw = lines[k]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { k -= 1; continue }
            if isPlainHorizontalRule(raw) {
                if crossedRule { break }
                crossedRule = true
                k -= 1
                continue
            }
            if trimmed.hasPrefix("╭") || trimmed.hasPrefix("╰") { return nil }
            break
        }
        // No rule between question and the next content → no preview block.
        if !crossedRule { return nil }

        var previewLines: [String] = []
        let maxLines = 18
        while k >= 0 && previewLines.count < maxLines {
            let raw = lines[k]
            var t = String(raw.drop(while: { $0 == " " }))
            let trimmed = t.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("╭") || trimmed.hasPrefix("╰") { break }
            // Intra-preview rules (e.g. between an "Edit file" header and the diff)
            // get skipped rather than ending the block.
            if isPlainHorizontalRule(raw) { k -= 1; continue }

            if t.hasPrefix("│") { t = String(t.dropFirst()) }
            if t.hasSuffix("│") { t = String(t.dropLast()) }
            while t.last == " " { t.removeLast() }

            previewLines.insert(t, at: 0)
            k -= 1
        }

        while previewLines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            previewLines.removeFirst()
        }
        while previewLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            previewLines.removeLast()
        }
        if previewLines.isEmpty { return nil }
        return previewLines.joined(separator: "\n")
    }

    /// Extracts the text the user has typed into Claude's input box.
    /// Handles both the current Claude TUI (`❯ <text>` bracketed by `───` rule separators)
    /// and the legacy `╭…╰` box format. Returns nil when no input is visible.
    func extractPromptInput(from lines: [String]) -> String? {
        // Rule-anchored: `❯ <text>` line adjacent to a horizontal-rule separator.
        for (idx, line) in lines.enumerated() {
            guard let content = Self.promptInputContent(line) else { continue }
            let lo = max(0, idx - 2)
            let hi = min(lines.count - 1, idx + 2)
            let nearSeparator = (lo...hi).contains { i in
                i != idx && Self.isPlainHorizontalRule(lines[i])
            }
            guard nearSeparator else { continue }
            return content
        }

        // Fallback: the rule check sometimes fails (terminal rendering edge cases
        // with pasted text, color attributes, etc.). Any `❯ <non-placeholder>` line
        // in the bottom slice of the buffer is treated as live input — Claude's TUI
        // only emits `❯` for the active prompt area, never for scrollback messages.
        let nonBlank = lines.filter { !$0.allSatisfy({ $0 == " " }) }
        for line in nonBlank.suffix(12).reversed() {
            guard let content = Self.promptInputContent(line) else { continue }
            return content
        }

        // Legacy fallback: `╭…╰` box.
        let sepIdx = lines.lastIndex(where: Self.isPlainHorizontalRule)
        let startIdx = sepIdx.map { $0 + 1 } ?? 0

        var inputLines: [String] = []
        var insideBox = false
        for line in lines[startIdx...] {
            let trimmed = String(line.drop(while: { $0 == " " }))
            if trimmed.hasPrefix("╭") { insideBox = true; continue }
            if trimmed.hasPrefix("╰") { break }
            guard insideBox else { continue }

            var content = trimmed
            if content.hasPrefix("│") { content = String(content.dropFirst()) }
            if content.hasSuffix("│") { content = String(content.dropLast()) }
            content = content.trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("> ") { content = String(content.dropFirst(2)) }
            if !content.isEmpty {
                inputLines.append(content)
            }
        }

        let result = inputLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }

    /// Returns the text after `❯ ` on the given line, if it's a text-input prompt.
    /// Returns nil for numbered choices (`❯ 1. Yes`) and Claude's `Try "..."` placeholder.
    fileprivate static func promptInputContent(_ line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " })
        guard trimmed.hasPrefix("❯ ") else { return nil }
        let rest = trimmed.dropFirst(2)
        if let first = rest.first, first.isNumber {
            let digits = rest.prefix(while: { $0.isNumber })
            if rest.dropFirst(digits.count).first == "." { return nil }
        }
        let content = String(rest).trimmingCharacters(in: .whitespaces)
        if content.isEmpty { return nil }
        if content.hasPrefix("Try \"") && content.hasSuffix("\"") { return nil }
        return content
    }

    private var diagFirstData = true
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)

        guard let id = sessionId else { return }
        if diagFirstData {
            diagFirstData = false
            NSLog("[NOTCHY-DIAG] FIRST dataReceived session=\(id) bytes=\(slice.count)")
        }

        // Mirror raw PTY output to any viewer Macs (and the backfill ring
        // buffer). Runs on main — LocalProcess delivers here by default.
        TerminalMirrorHub.shared.publish(sessionId: id, bytes: Data(slice))

        // Schedule a check 150ms after the first byte of a burst, but DON'T
        // reset the timer on every subsequent byte. Continuous data (spinner
        // animations, fast typing, paste echoes) would otherwise reschedule
        // faster than the debounce window and we'd never sample.
        if statusDebounceWork != nil { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.evaluateStatus(for: id)
            DispatchQueue.main.async { self.statusDebounceWork = nil }
        }
        statusDebounceWork = work
        Self.statusQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func evaluateStatus(for id: UUID) {
        // Snapshot the buffer once on the main thread (extractAllLines marshals
        // there); everything below is pure string parsing, safe on any queue.
        guard let lines = extractAllLines() else { return }
        guard let visibleText = extractVisibleText(from: lines) else { return }
        let fullText = extractFullVisibleText(from: lines) ?? visibleText

        var newStatus: TerminalStatus

        if Self.hasTokenCounterLine(visibleText) || fullText.contains("esc to interrupt") {
            newStatus = .working
        }
        else if fullText.contains("Esc to cancel") || Self.hasUserPrompt(fullText) {
            // Only a genuine pending question — confirmation overlay ("Esc to cancel")
            // or numbered choices. A bare input box is just normal idle.
            newStatus = .waitingForInput
        } else if visibleText.contains("Interrupted") {
            newStatus = .interrupted
        } else {
            newStatus = .idle
        }

        // Scrape pending prompt text unconditionally — status detection sometimes
        // mis-fires (computes .idle while the user is actively typing into the
        // input box), and the store's nil-guard protects against the Enter-wipe
        // race regardless of computed status.
        let pendingPrompt: String? = extractPromptInput(from: lines)
        // Capture interactive numbered choices + the question line above them + the preview block.
        var block: (choices: [PromptChoice], question: String?, preview: String?) =
            (newStatus == .waitingForInput) ? extractPromptBlock(from: lines) : ([], nil, nil)
        // Demote to .idle if we flagged .waitingForInput but couldn't actually
        // find a numbered prompt — e.g. the user's typed draft started with a
        // digit and tripped `hasUserPrompt`'s `❯ <digit>` match.
        if newStatus == .waitingForInput && block.choices.isEmpty {
            newStatus = .idle
            block = ([], nil, nil)
        }
        // Capture Claude's spinner/status line while working
        let activity: String? = (newStatus == .working) ? Self.activityLine(visibleText) : nil

        DispatchQueue.main.async {
            // Update pendingPromptText BEFORE the status transition so the
            // .working transition's freeze sees the latest scraped text. The
            // store's nil-guard preserves the draft during the Enter-wipe flicker.
            SessionStore.shared.updatePendingPromptText(id, text: pendingPrompt)
            if !SessionStore.shared.sessions.contains(where: { $0.id == id && $0.terminalStatus == newStatus }) {
                SessionStore.shared.updateTerminalStatus(id, status: newStatus)
            }
            SessionStore.shared.updatePendingChoices(id, choices: block.choices, question: block.question, preview: block.preview)
            SessionStore.shared.updateActivityLine(id, line: activity)
        }
    }

    /// Returns the Claude activity/spinner line (e.g. "✻ Brewing… (3s · ↑ 1.2k tokens · esc to interrupt)").
    private static func activityLine(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() {
            guard let first = line.first, spinnerCharacters.contains(first) else { continue }
            guard line.dropFirst().first == " " else { continue }
            guard line.contains("…") else { continue }
            return line.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Checks whether the text contains a Claude spinner character (visible during working state)
    private static let spinnerCharacters: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽"]

    /// Checks for a line like "Idle for 30s" — must contain " for " and end with "s",
    /// but must NOT contain parentheses (which indicate thinking duration, not true idle).
    private static func hasIdleForLine(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(" for ") else { return false }
            guard trimmed.hasSuffix("s") else { return false }
            guard !trimmed.contains("(") && !trimmed.contains(")") else { return false }
            return true
        }
    }

    /// Checks for the user prompt indicator: ❯ followed by a digit (1-9)
    private static func hasUserPrompt(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { line in
            let trimmed = line.drop(while: { $0 == " " })
            return trimmed.hasPrefix("❯") &&
                trimmed.dropFirst().first == " " &&
                trimmed.dropFirst(2).first?.isNumber == true
        }
    }

    /// Detects the current Claude TUI's text input: `❯ <text>` line bracketed by `───` rules.
    /// (The older `hasUserPrompt` only catches numbered-choice prompts.)
    private static func hasPromptInputLine(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (idx, line) in lines.enumerated() {
            guard promptInputContent(line) != nil else { continue }
            let lo = max(0, idx - 2)
            let hi = min(lines.count - 1, idx + 2)
            for i in lo...hi where i != idx {
                if isPlainHorizontalRule(lines[i]) { return true }
            }
        }
        // Fallback paired with extractPromptInput: rule check sometimes fails,
        // but a `❯ <non-placeholder>` line near the bottom is still live input.
        for line in lines.suffix(12) {
            if promptInputContent(line) != nil { return true }
        }
        return false
    }

    private static func hasTokenCounterLine(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { line in
            guard let first = line.first, spinnerCharacters.contains(first) else { return false }
            guard line.dropFirst().first == " " else { return false }
            return line.contains("…")
        }
    }
}

class TerminalManager: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalManager()

    private var terminals: [UUID: LocalProcessTerminalView] = [:]

    func terminal(for sessionId: UUID, workingDirectory: String, launchClaude: Bool = true) -> LocalProcessTerminalView {
        if let existing = terminals[sessionId] {
            NSLog("[NOTCHY-DIAG] terminal(for:) RETURN CACHED session=\(sessionId)")
            return existing
        }
        NSLog("[NOTCHY-DIAG] terminal(for:) CREATE session=\(sessionId) wd=\(workingDirectory) launchClaude=\(launchClaude)")

        let terminal = ClickThroughTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
        terminal.sessionId = sessionId
        terminal.processDelegate = self

        // Match macOS Terminal default font size
        terminal.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(white: 0.1, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let environment = buildEnvironment(claudeConfigDir: Self.claudeConfigDir(for: sessionId))

        // A nonexistent directory makes the child's chdir fail silently and the
        // shell would inherit the app's own cwd ("/") — fall back to home instead.
        var startDirectory = workingDirectory
        if startDirectory.isEmpty || !FileManager.default.fileExists(atPath: startDirectory) {
            startDirectory = NSHomeDirectory()
        }

        // Spawn the shell directly in the working directory rather than typing
        // a `cd` into it — input sent during login-shell init can be flushed
        // and silently dropped.
        terminal.startProcess(
            executable: shell,
            args: ["--login"],
            environment: environment,
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: startDirectory
        )
        let t = terminal.getTerminal()
        NSLog("[NOTCHY-DIAG] startProcess DONE session=\(sessionId) shell=\(shell) dir=\(startDirectory) cols=\(t.cols) rows=\(t.rows) frame=\(terminal.frame)")

        // Launch claude only if CLAUDE.md exists and integration is enabled.
        // Queued until the first OSC 7 cwd report (= first prompt) for the same reason.
        let hasClaude = launchClaude && SettingsManager.shared.claudeIntegrationEnabled && FileManager.default.fileExists(atPath: (workingDirectory as NSString).appendingPathComponent("CLAUDE.md"))
        if hasClaude {
            let claudeCommand = SettingsManager.shared.claudeAutoModeEnabled ? "claude --enable-auto-mode" : "claude"
            terminal.queueStartupCommand("clear && \(claudeCommand)\r", fallbackAfter: 3.0)
        }

        terminals[sessionId] = terminal
        return terminal
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        guard let sessionId = (source as? ClickThroughTerminalView)?.sessionId else { return }
        RemotePeerManager.shared.broadcastResize(
            sessionId: sessionId,
            cols: newCols,
            rows: newRows,
            to: TerminalMirrorHub.shared.subscribers(for: sessionId)
        )
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let terminal = source as? ClickThroughTerminalView else { return }
        // First OSC 7 report means the shell finished init and drew its prompt —
        // it's now safe to send the queued startup command.
        DispatchQueue.main.async {
            terminal.flushPendingStartupCommand()
        }
        guard let raw = directory,
              let sessionId = terminal.sessionId,
              let path = Self.parseOSC7Path(raw) else { return }
        DispatchQueue.main.async {
            SessionStore.shared.updateWorkingDirectory(sessionId, directory: path)
        }
    }

    /// Parses an OSC 7 payload (e.g. `file://hostname/Users/foo/My%20Project`) into
    /// a plain filesystem path. Returns nil for empty, malformed, or non-existent paths.
    static func parseOSC7Path(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let path: String
        if let url = URL(string: trimmed), url.isFileURL {
            path = url.path
        } else if trimmed.hasPrefix("/") {
            path = trimmed.removingPercentEncoding ?? trimmed
        } else {
            return nil
        }
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        NSLog("[NOTCHY-DIAG] processTerminated session=\((source as? ClickThroughTerminalView)?.sessionId?.uuidString ?? "nil") exit=\(exitCode.map(String.init) ?? "nil")")
        if let sessionId = (source as? ClickThroughTerminalView)?.sessionId {
            TerminalMirrorHub.shared.sessionEnded(sessionId)
        }
    }

    /// Returns the visible text from a terminal's buffer
    func visibleText(for sessionId: UUID) -> String? {
        guard let terminal = terminals[sessionId] as? ClickThroughTerminalView else { return nil }
        guard let lines = terminal.extractAllLines() else { return nil }
        return terminal.extractVisibleText(from: lines)
    }

    /// Sends raw input to a session's terminal (used by Conductor to submit numbered choices).
    func sendInput(to sessionId: UUID, text: String) {
        terminals[sessionId]?.send(txt: text)
    }

    /// Injects raw bytes from a viewer Mac's keyboard — same path as local
    /// typing (TerminalView.send routes through the delegate to the process).
    func sendRawInput(to sessionId: UUID, data: Data) {
        terminals[sessionId]?.send(data: ArraySlice([UInt8](data)))
    }

    /// Force this session's PTY grid to a viewer's requested dims (SIGWINCH to
    /// the child). Only called while a remote viewer is driving the size.
    func applyRemoteResize(sessionId: UUID, cols: Int, rows: Int) {
        guard let terminal = terminals[sessionId] else { return }
        let current = terminal.getTerminal()
        guard current.cols != cols || current.rows != rows else { return }
        terminal.resize(cols: cols, rows: rows)
    }

    /// Restore a session's grid to whatever its own view frame implies — undoes
    /// a viewer-driven resize once the viewer detaches.
    func restoreNaturalSize(sessionId: UUID) {
        guard let terminal = terminals[sessionId] else { return }
        terminal.setFrameSize(terminal.frame.size)  // re-derives cols/rows from frame
    }

    /// Current PTY dims for a session, for mirror subscriptions.
    func terminalSize(for sessionId: UUID) -> (cols: Int, rows: Int)? {
        guard let terminal = terminals[sessionId]?.getTerminal() else { return nil }
        return (terminal.cols, terminal.rows)
    }

    func destroyTerminal(for sessionId: UUID) {
        terminals.removeValue(forKey: sessionId)
        TerminalMirrorHub.shared.sessionEnded(sessionId)
    }

    /// Resolves the `CLAUDE_CONFIG_DIR` for a session by walking session → group
    /// → account. Returns nil for the default `~/.claude` login. Creates the
    /// account's config dir on demand so `claude` can write credentials into it.
    private static func claudeConfigDir(for sessionId: UUID) -> String? {
        guard let groupId = SessionStore.shared.sessions.first(where: { $0.id == sessionId })?.groupId,
              let group = SessionStore.shared.projectGroups.first(where: { $0.id == groupId }),
              let account = SettingsManager.shared.account(for: group.accountId) else { return nil }
        let url = account.configDirURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func buildEnvironment(claudeConfigDir: String? = nil) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        // Per-project Claude account: point claude at this account's own config
        // directory so it uses that account's credentials.
        if let claudeConfigDir { env["CLAUDE_CONFIG_DIR"] = claudeConfigDir }
        // macOS's stock zsh/bash only emit OSC 7 cwd reports (which feed
        // hostCurrentDirectoryUpdate → session persistence) when
        // /etc/zshrc_Apple_Terminal is sourced, gated on this variable.
        env["TERM_PROGRAM"] = "Apple_Terminal"
        // Without a session ID the Apple_Terminal rc skips its shell-session
        // save/restore machinery — we only want the cwd reporting.
        env.removeValue(forKey: "TERM_SESSION_ID")
        return env.map { "\($0.key)=\($0.value)" }
    }
}
