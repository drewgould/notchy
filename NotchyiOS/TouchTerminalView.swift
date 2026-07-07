import SwiftUI

/// SwiftUI wrapper that attaches the mirror terminal for a remote session inside
/// a letterboxing container and makes it first responder (so the soft keyboard
/// appears). The macOS counterpart is `RemoteTerminalSessionView`.
struct TouchTerminalView: UIViewRepresentable {
    let sessionId: UUID
    let machineId: UUID

    func makeUIView(context: Context) -> UIView {
        let container = LetterboxContainerView()
        container.backgroundColor = UIColor(white: 0.1, alpha: 1.0)
        let term = TouchRemoteTerminalManager.shared.terminal(for: sessionId, machineId: machineId)
        term.removeFromSuperview()
        term.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(term)
        container.setNeedsLayout()
        DispatchQueue.main.async { term.becomeFirstResponder() }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
