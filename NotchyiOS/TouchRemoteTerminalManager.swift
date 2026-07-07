import UIKit
import SwiftTerm

/// iOS mirror terminal: a SwiftTerm `TerminalView` with no local process, fed by
/// network bytes. Keystrokes leave through the delegate as `termInput` frames;
/// the worker's PTY echoes them back via `termData`. UIKit counterpart of the
/// macOS `RemoteMirrorTerminalView`.
final class MirrorTerminalView: TerminalView {
    var remoteSessionId: UUID?
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
        terminals.removeValue(forKey: sessionId)?.removeFromSuperview()
        machineForSession.removeValue(forKey: sessionId)
    }

    /// Send raw bytes (used by the key-accessory bar) — routes through the same
    /// delegate path as typing, so it reaches the worker's PTY.
    func sendBytes(_ bytes: [UInt8], to sessionId: UUID) {
        terminals[sessionId]?.send(data: ArraySlice(bytes))
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

    /// The worker's PTY size is authoritative; adopt its cols/rows and let the
    /// container letterbox the resulting fixed-size frame.
    private func applyRemoteSize(sessionId: UUID, cols: Int, rows: Int, from machineId: UUID) {
        guard machineForSession[sessionId] == machineId,
              let view = terminals[sessionId], cols > 0, rows > 0 else { return }
        view.resize(cols: cols, rows: rows)
        view.frame.size = view.getOptimalFrameSize().size
        view.superview?.setNeedsLayout()
    }

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
        // Viewer never dictates size — the worker's PTY is authoritative.
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
