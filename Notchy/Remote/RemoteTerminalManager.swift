import AppKit
import SwiftTerm

/// Viewer-side mirror of a worker Mac's terminal: a plain SwiftTerm
/// `TerminalView` (no local process) fed by network bytes. Keystrokes go out
/// through the delegate as `termInput` frames; the worker's PTY echoes them
/// back through `termData`.
class RemoteMirrorTerminalView: TerminalView {
    var remoteSessionId: UUID?
    private var keyMonitor: Any?

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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    /// Unlike the local drop (which types the dropped path straight in), a mirror
    /// has to ship the bytes: the worker Mac has no file at this path — or worse,
    /// has a *different* file there. `sendDroppedFiles` streams them over and the
    /// worker types the path it actually wrote.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let sessionId = remoteSessionId,
              let urls = sender.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]
              ) as? [URL], !urls.isEmpty else {
            return false
        }
        RemoteTerminalManager.shared.sendDroppedFiles(urls, to: sessionId)
        return true
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Same workaround as ClickThroughTerminalView: intercept arrow keys and
    /// send plain VT100 sequences to dodge kitty keyboard protocol (CSI u)
    /// encoding issues — the bytes still route through the delegate to the
    /// worker's PTY.
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

    /// Send typed characters as plain text, bypassing SwiftTerm's kitty
    /// keyboard-protocol encoding.
    ///
    /// Claude Code turns on the kitty keyboard protocol, and the mirror inherits
    /// those flags by replaying the worker's output stream. SwiftTerm then
    /// encodes every keystroke as a kitty key-event (CSI u) — see
    /// `MacTerminalView.insertText` — instead of literal text. Routed through the
    /// worker that way, typed characters never echo back on the mirror even
    /// though the line still submits on Return. This is the same kitty issue the
    /// arrow-key monitor above already sidesteps; here we finish the job for
    /// printable input. The worker's Claude accepts plain text fine even in kitty
    /// mode (the arrow workaround relies on the same thing).
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = string as? NSString else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        send(txt: text as String)
    }
}

/// Owns the viewer-side terminal views, keyed by the REMOTE session id —
/// mirrors TerminalManager's dictionary pattern. Also the single
/// TerminalViewDelegate for all mirror views.
class RemoteTerminalManager: NSObject, TerminalViewDelegate, RemoteTerminalSink {
    static let shared = RemoteTerminalManager()

    private var terminals: [UUID: RemoteMirrorTerminalView] = [:]
    private var machineForSession: [UUID: UUID] = [:]

    func terminal(for sessionId: UUID, machineId: UUID) -> RemoteMirrorTerminalView {
        if let existing = terminals[sessionId] {
            return existing
        }
        let view = RemoteMirrorTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
        view.remoteSessionId = sessionId
        view.terminalDelegate = self
        // Match TerminalManager's local terminal appearance.
        view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        view.nativeBackgroundColor = NSColor(white: 0.1, alpha: 1.0)
        view.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)
        terminals[sessionId] = view
        machineForSession[sessionId] = machineId
        RemotePeerManager.shared.subscribe(machineId: machineId, sessionId: sessionId)
        return view
    }

    /// Stream files dropped on a mirror to the worker that owns the session.
    /// The worker writes them to its own temp dir and types those paths.
    @MainActor
    func sendDroppedFiles(_ urls: [URL], to sessionId: UUID) {
        guard let machineId = machineForSession[sessionId] else {
            print("[remote] ignoring drop — no machine for session \(sessionId)")
            return
        }
        FileDropCoordinator.shared.drop(urls, sessionId: sessionId, machineId: machineId)
    }

    func destroyTerminal(for sessionId: UUID) {
        if let machineId = machineForSession[sessionId] {
            RemotePeerManager.shared.unsubscribe(machineId: machineId, sessionId: sessionId)
        }
        terminals.removeValue(forKey: sessionId)?.removeFromSuperview()
        machineForSession.removeValue(forKey: sessionId)
    }

    /// Peer reconnected — refresh every live mirror with a new subscribe;
    /// the fresh reset+snapshot fixes any drift accumulated while offline.
    func peerCameOnline(_ machineId: UUID) {
        for (sessionId, machine) in machineForSession where machine == machineId {
            RemotePeerManager.shared.subscribe(machineId: machineId, sessionId: sessionId)
        }
    }

    /// Peer vanished — keep the frozen view content; the UI overlays offline
    /// state from `session.isPeerOnline`.
    func peerWentOffline(_ machineId: UUID) {}

    // MARK: - Incoming frames (main thread, via RemotePeerManager)

    func handleTermData(sessionId: UUID, bytes: Data, isSnapshot: Bool, from machineId: UUID) {
        guard machineForSession[sessionId] == machineId,
              let view = terminals[sessionId] else { return }
        // feed() on main only — SwiftTerm's buffer races with reflow off-main.
        view.feed(byteArray: ArraySlice([UInt8](bytes)))
    }

    func handleSubscribeAck(_ ack: SubscribeAckMessage, from machineId: UUID) {
        guard ack.accepted else { return }
        applyRemoteSize(sessionId: ack.sessionId, cols: ack.cols, rows: ack.rows, from: machineId)
    }

    func handleResize(_ message: ResizeMessage, from machineId: UUID) {
        applyRemoteSize(sessionId: message.sessionId, cols: message.cols, rows: message.rows, from: machineId)
    }

    /// The worker's PTY size is authoritative; the mirror adopts its cols/rows
    /// and the container letterboxes the resulting frame.
    private func applyRemoteSize(sessionId: UUID, cols: Int, rows: Int, from machineId: UUID) {
        guard machineForSession[sessionId] == machineId,
              let view = terminals[sessionId],
              cols > 0, rows > 0 else { return }
        view.resize(cols: cols, rows: rows)
        view.setFrameSize(view.getOptimalFrameSize().size)
        view.superview?.needsLayout = true
    }

    func handleSessionClosed(_ sessionId: UUID, from machineId: UUID) {
        guard machineForSession[sessionId] == machineId else { return }
        // The PTY died on the worker (restart/close). Tab removal rides the
        // sessionList; here we just tear down the dead mirror so a future
        // selection re-subscribes cleanly.
        destroyTerminal(for: sessionId)
    }

    // MARK: - TerminalViewDelegate (viewer keystrokes → worker)

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let view = source as? RemoteMirrorTerminalView,
              let sessionId = view.remoteSessionId,
              let machineId = machineForSession[sessionId] else { return }
        RemotePeerManager.shared.sendTermInput(machineId: machineId, sessionId: sessionId, bytes: Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Viewer never dictates size — the worker's PTY is authoritative.
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(bytes: content, encoding: .utf8) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(str, forType: .string)
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
