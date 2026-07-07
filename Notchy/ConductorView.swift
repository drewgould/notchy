import SwiftUI

/// Overview of every session: live status, per-tab prompt/response history
/// with verification checkboxes, and a global Claude Code usage summary at
/// the top. Arrow keys / Enter target the first session with pending choices.
struct ConductorView: View {
    @Bindable var sessionStore: SessionStore
    var usageMonitor = UsageMonitor.shared
    /// Called when the user clicks a session's project name to jump into it.
    var onSessionSelected: ((UUID) -> Void)? = nil
    /// Per-session keyboard highlight: signature (choice numbers) + selected index.
    /// Signature lets us invalidate the override when a fresh prompt arrives.
    @State private var localHighlights: [UUID: (signature: [Int], index: Int)] = [:]
    @FocusState private var keyboardFocused: Bool
    /// Captured at drag-start, cleared at drag-end. While non-nil we render
    /// against this frozen list instead of `sessionStore.sessions` — keeps
    /// the LazyVStack from re-diffing rows while the tab bar's drop delegate
    /// rapidly mutates the underlying array (otherwise prone to crash).
    @State private var dragSnapshot: [TerminalSession]?

    private var displayedSessions: [TerminalSession] {
        dragSnapshot ?? sessionStore.sessions
    }

    /// First session in display order with pending choices — this is the one
    /// arrow keys/Enter target.
    private var keyboardTarget: TerminalSession? {
        displayedSessions.first(where: { !$0.pendingChoices.isEmpty })
    }

    private func highlightedNumber(for session: TerminalSession) -> Int? {
        guard !session.pendingChoices.isEmpty else { return nil }
        let sig = session.pendingChoices.map(\.number)
        if let entry = localHighlights[session.id],
           entry.signature == sig,
           session.pendingChoices.indices.contains(entry.index) {
            return session.pendingChoices[entry.index].number
        }
        return session.pendingChoices.first(where: { $0.isSelected })?.number
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                UsageHeader(monitor: usageMonitor)
                    .padding(.bottom, 4)

                if displayedSessions.isEmpty {
                    Text("No sessions")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 40)
                } else {
                    ForEach(displayedSessions) { session in
                        ConductorRow(
                            session: session,
                            sessionStore: sessionStore,
                            highlightedNumber: highlightedNumber(for: session),
                            onSessionSelected: onSessionSelected
                        )
                    }
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: NSColor(white: 0.1, alpha: 1.0)))
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onAppear { keyboardFocused = keyboardTarget != nil }
        .onChange(of: keyboardTarget?.id) { _, new in
            if new != nil { keyboardFocused = true }
        }
        .onChange(of: sessionStore.draggedSessionId) { _, new in
            if new != nil, dragSnapshot == nil {
                dragSnapshot = sessionStore.sessions
            } else if new == nil {
                dragSnapshot = nil
            }
        }
        .onKeyPress(.upArrow) { moveHighlight(by: -1) }
        .onKeyPress(.downArrow) { moveHighlight(by: 1) }
        .onKeyPress(.return) { submitHighlighted() }
    }

    private func currentIndex(in session: TerminalSession) -> Int {
        let sig = session.pendingChoices.map(\.number)
        if let entry = localHighlights[session.id],
           entry.signature == sig,
           session.pendingChoices.indices.contains(entry.index) {
            return entry.index
        }
        return session.pendingChoices.firstIndex(where: { $0.isSelected }) ?? 0
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        guard let s = keyboardTarget, !s.pendingChoices.isEmpty else { return .ignored }
        let count = s.pendingChoices.count
        let next = (currentIndex(in: s) + delta + count) % count
        localHighlights[s.id] = (s.pendingChoices.map(\.number), next)
        return .handled
    }

    private func submitHighlighted() -> KeyPress.Result {
        guard let s = keyboardTarget, !s.pendingChoices.isEmpty else { return .ignored }
        let number = s.pendingChoices[currentIndex(in: s)].number
        sessionStore.submitChoice(s.id, number: number)
        return .handled
    }
}

private struct ConductorRow: View {
    let session: TerminalSession
    @Bindable var sessionStore: SessionStore
    /// When non-nil, overrides the terminal-buffer-derived `isSelected` for
    /// visual highlighting. Reflects the conductor's keyboard cursor.
    var highlightedNumber: Int? = nil
    var onSessionSelected: ((UUID) -> Void)? = nil

    private var statusLabel: String {
        switch session.terminalStatus {
        case .working: return "Working"
        case .waitingForInput: return "Waiting for input"
        case .interrupted: return "Interrupted"
        case .taskCompleted: return "Done"
        case .idle: return "Idle"
        }
    }

    private var statusColor: Color {
        switch session.terminalStatus {
        case .working: return .yellow
        case .waitingForInput: return .red
        case .interrupted: return .orange
        case .taskCompleted: return .green
        case .idle: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: {
                    sessionStore.selectSession(session.id)
                    onSessionSelected?(session.id)
                }) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)

                StatusPill(label: statusLabel, color: statusColor)

                if session.terminalStatus == .working, let started = session.workingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(formatElapsed(context.date.timeIntervalSince(started)))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundColor(.white.opacity(0.7))
                    }
                }

                Spacer()

                if !session.exchanges.isEmpty {
                    let visible = session.exchanges.suffix(5)
                    let verified = visible.filter(\.verified).count
                    Text("\(verified)/\(visible.count) verified")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                }
            }

            // Live draft (text the user is currently typing into Claude's input box).
            // Suppress when a confirmation preview is showing — the preview is more relevant.
            if let draft = session.pendingPromptText, !draft.isEmpty,
               session.terminalStatus != .working,
               session.pendingPromptPreview == nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Drafting:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                    Text(draft)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }

            // Spinner / activity line during work
            if session.terminalStatus == .working, let activity = session.activityLine {
                Text(activity)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Numbered choices Claude is waiting on
            if session.terminalStatus == .waitingForInput, !session.pendingChoices.isEmpty {
                choicesView
            }

            // Exchange history — most recent first, capped at 5.
            // When input is pending, collapse rows so the orange action card stays dominant.
            if !session.exchanges.isEmpty {
                let pending = session.terminalStatus == .waitingForInput && !session.pendingChoices.isEmpty
                VStack(alignment: .leading, spacing: pending ? 3 : 6) {
                    ForEach(session.exchanges.suffix(5).reversed()) { exchange in
                        ExchangeRow(
                            exchange: exchange,
                            compact: pending,
                            onToggle: { sessionStore.setExchangeVerified(session.id, exchangeId: exchange.id, !exchange.verified) }
                        )
                    }
                }
                .padding(.top, pending ? 2 : 0)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var choicesView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preview = session.pendingPromptPreview, !preview.isEmpty {
                PromptPreviewView(text: preview)
                    .padding(.bottom, 2)
            }
            if let question = session.pendingQuestion {
                questionHeader(question)
            }
            ForEach(session.pendingChoices) { choice in
                ChoiceButton(
                    choice: choice,
                    isHighlighted: highlightedNumber.map { $0 == choice.number } ?? choice.isSelected,
                    onTap: { sessionStore.submitChoice(session.id, number: choice.number) }
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: Color.orange.opacity(0.25), radius: 6, x: 0, y: 0)
    }

    @ViewBuilder
    private func questionHeader(_ question: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.orange)
            Text(question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(.bottom, 2)
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct ChoiceButton: View {
    let choice: PromptChoice
    let isHighlighted: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text("\(choice.number)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(isHighlighted ? .black : .white.opacity(0.85))
                    .frame(width: 18, height: 18)
                    .background(numberBackground)
                Text(choice.label)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(rowBackground)
            .overlay(rowBorder)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var numberBackground: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(isHighlighted ? Color.orange : Color.white.opacity(0.12))
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isHighlighted ? Color.orange.opacity(0.18) : Color.white.opacity(0.05))
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(isHighlighted ? Color.orange.opacity(0.7) : Color.white.opacity(0.10), lineWidth: 1)
    }
}

private struct ExchangeRow: View {
    let exchange: TaskExchange
    /// When true, an active prompt is pending — show only one line and hide summary
    /// detail so the orange action card stays visually dominant.
    var compact: Bool = false
    let onToggle: () -> Void

    private var inProgress: Bool { exchange.completedAt == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if inProgress {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.top, 1)
                    .frame(width: compact ? 12 : 14, height: compact ? 12 : 14)
            } else if exchange.wasInterrupted {
                Button(action: onToggle) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: compact ? 12 : 14, weight: .regular))
                        .foregroundColor(.orange)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            } else {
                Button(action: onToggle) {
                    Image(systemName: exchange.verified ? "checkmark.square.fill" : "square")
                        .font(.system(size: compact ? 12 : 14, weight: .regular))
                        .foregroundColor(exchange.verified ? .accentColor : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(exchange.prompt)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(exchange.verified || compact ? 0.45 : 0.9))
                    .strikethrough(exchange.verified, color: .white.opacity(0.45))
                    .lineLimit(compact || exchange.verified ? 1 : 3)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copy Prompt") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(exchange.prompt, forType: .string)
                        }
                    }

                if !exchange.verified && !compact {
                    summaryView
                }
            }
        }
        .padding(compact ? 5 : 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(exchange.verified ? 0.02 : 0.04))
        )
        .opacity(compact ? 0.55 : (exchange.verified ? 0.7 : 1.0))
    }

    @ViewBuilder
    private var summaryView: some View {
        switch exchange.summaryStatus {
        case .generating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Summarizing…")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
        case .ready:
            if let summary = exchange.summary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(exchange.verified ? 0.55 : 0.8))
                    .strikethrough(exchange.verified, color: .white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed:
            Text("Couldn't generate summary (check API key in Settings → Integrations).")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
        case .none:
            if exchange.completedAt == nil {
                Text("In progress…")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }
}

/// Renders the scraped preview block above a confirmation question — typically
/// a diff for an edit, a command body for a Bash prompt, or a URL for WebFetch.
/// Lines starting with a number followed by `-`/`+` (diff markers from Claude's
/// TUI) get tinted red/green; everything else is rendered as plain monospaced text.
private struct PromptPreviewView: View {
    let text: String

    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(color(for: line))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// Tints diff lines red/green based on Claude TUI's `NNN -` / `NNN +` prefix.
    /// Anything else (file headers, command bodies, URLs) stays neutral white.
    private func color(for line: Substring) -> Color {
        let stripped = line.drop(while: { $0 == " " })
        let afterDigits = stripped.drop(while: { $0.isNumber })
        guard afterDigits.count != stripped.count else {
            return .white.opacity(0.78)
        }
        let trimmed = afterDigits.drop(while: { $0 == " " })
        switch trimmed.first {
        case "-": return Color.red.opacity(0.85)
        case "+": return Color.green.opacity(0.85)
        default:  return .white.opacity(0.78)
        }
    }
}

private struct StatusPill: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(color.opacity(0.15))
        )
    }
}

private struct UsageHeader: View {
    @Bindable var monitor: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Text("Claude Code Usage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                if monitor.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else if let fetched = monitor.snapshot?.fetchedAt {
                    Text(timeAgo(fetched))
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }
                Button(action: { monitor.refreshNow() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Refresh now")
            }

            if let snap = monitor.snapshot {
                if let plan = snap.plan {
                    Text(plan)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                }
                if !snap.windows.isEmpty {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(snap.windows) { window in
                            UsagePie(window: window)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if snap.windows.isEmpty, snap.plan == nil {
                    Text("Couldn't parse /usage output.")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
            } else if let err = monitor.lastError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                Text("Fetching usage…")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func timeAgo(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 5 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        let m = secs / 60
        return "\(m)m ago"
    }
}

private struct UsagePie: View {
    let window: UsageWindow

    private var fraction: CGFloat {
        CGFloat(max(0, min(window.percent, 100))) / 100.0
    }

    private var pieColor: Color {
        if window.percent >= 90 { return .red }
        if window.percent >= 70 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                PieSliceShape(fraction: fraction)
                    .fill(pieColor)
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(window.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.78))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(window.percent)%")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundColor(pieColor.opacity(0.95))
                    if let resets = window.resets {
                        Text("· \(resets)")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .help(window.resets.map { "\(window.label): \(window.percent)% · \($0)" } ?? "\(window.label): \(window.percent)%")
    }
}

/// Center-anchored wedge that grows counter-clockwise from 12 o'clock.
private struct PieSliceShape: Shape {
    var fraction: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard fraction > 0 else { return p }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let start = Angle.degrees(-90)
        let end = Angle.degrees(-90 - 360 * Double(min(fraction, 1)))
        p.move(to: center)
        // SwiftUI's `clockwise` is inverted from screen direction (y-down), so
        // `clockwise: true` here draws counter-clockwise on screen.
        p.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        p.closeSubpath()
        return p
    }
}
