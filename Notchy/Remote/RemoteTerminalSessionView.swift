import SwiftUI
import SwiftTerm

/// Centers the mirror terminal at its natural size for the worker's
/// cols/rows — the letterbox that keeps both ends' PTY dims identical.
private class RemoteTerminalContainerView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard let terminal = subviews.first else { return }
        // A mirror that hasn't received its dims yet fills the container.
        if terminal.frame.size == .zero {
            terminal.frame = bounds
            return
        }
        let size = terminal.frame.size
        terminal.setFrameOrigin(NSPoint(
            x: max(0, (bounds.width - size.width) / 2),
            y: max(0, (bounds.height - size.height) / 2)
        ))
    }
}

/// Viewer-side counterpart of TerminalSessionView: attaches the mirror view
/// for a remote session and subscribes to its byte stream.
struct RemoteTerminalSessionView: NSViewRepresentable {
    let sessionId: UUID
    let machineId: UUID

    class Coordinator {
        var currentSessionId: UUID?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = RemoteTerminalContainerView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1.0).cgColor
        attachTerminal(to: container, context: context)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if context.coordinator.currentSessionId != sessionId {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            attachTerminal(to: nsView, context: context)
        }
    }

    private func attachTerminal(to container: NSView, context: Context) {
        context.coordinator.currentSessionId = sessionId
        let terminal = RemoteTerminalManager.shared.terminal(for: sessionId, machineId: machineId)
        terminal.removeFromSuperview()
        // Manual frames (not constraints): the container's layout() centers
        // the terminal at the fixed size the worker's dims dictate.
        terminal.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(terminal)
        container.needsLayout = true

        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
    }
}
