import UIKit
import SwiftTerm

/// iOS mirror terminal: a SwiftTerm `TerminalView` with no local process, fed by
/// network bytes. Keystrokes leave through the delegate as `termInput` frames;
/// the worker's PTY echoes them back via `termData`. UIKit counterpart of the
/// macOS `RemoteMirrorTerminalView`.
final class MirrorTerminalView: TerminalView {
    var remoteSessionId: UUID?

    /// Send typed characters as plain text, bypassing SwiftTerm's kitty
    /// keyboard-protocol encoding — the iOS counterpart of the macOS mirror's
    /// override.
    ///
    /// Claude Code turns on the kitty keyboard protocol, and the mirror inherits
    /// those flags by replaying the worker's output. `commitTextInput` then
    /// encodes each keystroke as a kitty key-event (CSI u) instead of literal
    /// text, and routed through the worker that way, typed characters never echo
    /// back even though the line still submits on Return. Sending plain text
    /// avoids that; the worker's Claude accepts it fine even in kitty mode.
    ///
    /// Return arrives here as "\n" on iOS (unlike macOS, where it routes through
    /// insertNewline), so it still needs the terminal's CR sequence rather than a
    /// literal newline. Control/meta and other special keys come through
    /// pressesBegan, and the accessory bar sends bytes directly — neither touches
    /// this path.
    override func insertText(_ text: String) {
        if text == "\n" {
            send(returnByteSequence)
        } else {
            send(txt: text)
        }
    }
}

/// Centers the mirror terminal at its natural size for the worker's cols/rows —
/// the letterbox that keeps both ends' PTY dims identical. (Optimal iPad-driven
/// sizing is a later step; for now we honor the worker's grid.)
final class LetterboxContainerView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let term = subviews.first else { return }
        if term.frame.size == .zero {
            term.frame = bounds
            return
        }
        let size = term.frame.size
        term.frame.origin = CGPoint(
            x: max(0, (bounds.width - size.width) / 2),
            y: max(0, (bounds.height - size.height) / 2)
        )
    }
}

/// Owns the viewer-side terminal views keyed by remote session id, and is the
/// single `TerminalViewDelegate` for all of them. Injected into
/// `RemoteRuntime.terminalSink` at launch.
final class TouchRemoteTerminalManager: NSObject, TerminalViewDelegate, RemoteTerminalSink {
    static let shared = TouchRemoteTerminalManager()

    private var terminals: [UUID: MirrorTerminalView] = [:]
    private var machineForSession: [UUID: UUID] = [:]
    /// Debounces resize requests so rotation / keyboard changes don't storm the worker.
    private var resizeWork: [UUID: DispatchWorkItem] = [:]

    func terminal(for sessionId: UUID, machineId: UUID) -> MirrorTerminalView {
        if let existing = terminals[sessionId] { return existing }
        let view = MirrorTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.remoteSessionId = sessionId
        view.terminalDelegate = self
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = UIColor(white: 0.1, alpha: 1.0)
        view.nativeForegroundColor = UIColor(white: 0.9, alpha: 1.0)
        terminals[sessionId] = view
        machineForSession[sessionId] = machineId
        RemotePeerManager.shared.subscribe(machineId: machineId, sessionId: sessionId)
        return view
    }

    func destroyTerminal(for sessionId: UUID) {
        if let machineId = machineForSession[sessionId] {
            RemotePeerManager.shared.unsubscribe(machineId: machineId, sessionId: sessionId)
        }
        resizeWork[sessionId]?.cancel()
        resizeWork.removeValue(forKey: sessionId)
        terminals.removeValue(forKey: sessionId)?.removeFromSuperview()
        machineForSession.removeValue(forKey: sessionId)
    }

    /// Ask the worker to size its PTY to the grid this device's terminal just
    /// computed for its own screen. Debounced.
    private func scheduleResizeRequest(machineId: UUID, sessionId: UUID, cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        resizeWork[sessionId]?.cancel()
        let work = DispatchWorkItem {
            RemotePeerManager.shared.sendResizeRequest(
                machineId: machineId, sessionId: sessionId, cols: cols, rows: rows)
        }
        resizeWork[sessionId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Send raw bytes (used by the key-accessory bar) — routes through the same
    /// delegate path as typing, so it reaches the worker's PTY.
    func sendBytes(_ bytes: [UInt8], to sessionId: UUID) {
        terminals[sessionId]?.send(data: ArraySlice(bytes))
    }

    /// Send a pasted screenshot to the worker, which stages it on its clipboard
    /// and hands it to Claude. Downscaled to Claude's vision bound and PNG-
    /// encoded first so it fits a single frame. Returns false if the image
    /// couldn't be encoded or the session isn't attached.
    @discardableResult
    func sendImage(_ image: UIImage, to sessionId: UUID) -> Bool {
        guard let machineId = machineForSession[sessionId],
              let png = Self.encodeForPaste(image) else { return false }
        RemotePeerManager.shared.sendTermImage(machineId: machineId, sessionId: sessionId, png: png)
        return true
    }

    /// Stream files dropped on the mirror to the worker, which writes them to its
    /// own temp dir and types those paths — a path from this iPad would mean
    /// nothing over there. Returns false if the session isn't attached or the
    /// drop held nothing sendable.
    @MainActor
    @discardableResult
    func sendDroppedFiles(_ urls: [URL], to sessionId: UUID) -> Bool {
        guard let machineId = machineForSession[sessionId] else { return false }
        return FileDropCoordinator.shared.drop(urls, sessionId: sessionId, machineId: machineId)
    }

    /// Downscale to ~1568px on the longest edge (Claude's vision bound — larger
    /// buys nothing) and PNG-encode, keeping the payload well under the frame cap.
    private static func encodeForPaste(_ image: UIImage) -> Data? {
        let maxEdge: CGFloat = 1568
        let px = CGSize(width: image.size.width * image.scale,
                        height: image.size.height * image.scale)
        guard px.width > 0, px.height > 0 else { return nil }
        let factor = min(1, maxEdge / max(px.width, px.height))
        let target = CGSize(width: (px.width * factor).rounded(),
                            height: (px.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.pngData()
    }

    // MARK: - RemoteTerminalSink

    func peerCameOnline(_ machineId: UUID) {
        for (sessionId, machine) in machineForSession where machine == machineId {
            RemotePeerManager.shared.subscribe(machineId: machineId, sessionId: sessionId)
        }
    }

    func peerWentOffline(_ machineId: UUID) {}

    func handleTermData(sessionId: UUID, bytes: Data, isSnapshot: Bool, from machineId: UUID) {
        guard machineForSession[sessionId] == machineId, let view = terminals[sessionId] else { return }
        view.feed(byteArray: ArraySlice([UInt8](bytes)))
    }

    func handleSubscribeAck(_ ack: SubscribeAckMessage, from machineId: UUID) {
        guard ack.accepted else { return }
        applyRemoteSize(sessionId: ack.sessionId, cols: ack.cols, rows: ack.rows, from: machineId)
    }

    func handleResize(_ message: ResizeMessage, from machineId: UUID) {
        applyRemoteSize(sessionId: message.sessionId, cols: message.cols, rows: message.rows, from: machineId)
    }

    /// This device drives its own size (the terminal fills the screen and its
    /// grid is pushed to the worker via resizeRequest), so the worker's echoed
    /// dims are ignored — adopting them would fight the fill and oscillate.
    private func applyRemoteSize(sessionId: UUID, cols: Int, rows: Int, from machineId: UUID) {}

    func handleSessionClosed(_ sessionId: UUID, from machineId: UUID) {
        guard machineForSession[sessionId] == machineId else { return }
        destroyTerminal(for: sessionId)
    }

    // MARK: - TerminalViewDelegate (viewer keystrokes → worker)

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let view = source as? MirrorTerminalView,
              let sessionId = view.remoteSessionId,
              let machineId = machineForSession[sessionId] else { return }
        RemotePeerManager.shared.sendTermInput(machineId: machineId, sessionId: sessionId, bytes: Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // The terminal filled our screen and computed this grid — push it to the
        // worker so its PTY (and thus Claude's TUI) matches this device exactly.
        guard let view = source as? MirrorTerminalView,
              let sessionId = view.remoteSessionId,
              let machineId = machineForSession[sessionId] else { return }
        scheduleResizeRequest(machineId: machineId, sessionId: sessionId, cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    /// iOS has no default (macOS opens via NSWorkspace) — open tapped links in Safari.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(bytes: content, encoding: .utf8) {
            UIPasteboard.general.string = str
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
