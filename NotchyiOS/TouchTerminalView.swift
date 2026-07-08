import SwiftUI

/// SwiftUI wrapper that attaches the mirror terminal for a remote session inside
/// a letterboxing container and makes it first responder (so the soft keyboard
/// appears). The macOS counterpart is `RemoteTerminalSessionView`.
struct TouchTerminalView: UIViewRepresentable {
    let sessionId: UUID
    let machineId: UUID

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(white: 0.1, alpha: 1.0)
        let term = TouchRemoteTerminalManager.shared.terminal(for: sessionId, machineId: machineId)
        term.removeFromSuperview()
        // Fill the container: SwiftTerm derives the grid from this frame and
        // reports it via sizeChanged, which the manager forwards to the worker
        // as a resizeRequest — so the worker's PTY fits this screen.
        term.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(term)
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            term.topAnchor.constraint(equalTo: container.topAnchor),
            term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { term.becomeFirstResponder() }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
