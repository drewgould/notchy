import SwiftUI
import UIKit

/// A row of the terminal keys iOS soft keyboards lack — esc, tab, ctrl-C, and
/// arrows — sent to the worker's PTY as the raw escape sequences Claude's TUI
/// expects, plus a paste-screenshot button. Shown above the keyboard while a
/// terminal is open.
struct KeyAccessoryBar: View {
    let sessionId: UUID

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                key("esc") { send([0x1b]) }
                key("tab") { send([0x09]) }
                key("⌃C") { send([0x03]) }
                key(nil, systemImage: "arrow.up") { send([0x1b, 0x5b, 0x41]) }      // ESC [ A
                key(nil, systemImage: "arrow.down") { send([0x1b, 0x5b, 0x42]) }    // ESC [ B
                key(nil, systemImage: "arrow.left") { send([0x1b, 0x5b, 0x44]) }    // ESC [ D
                key(nil, systemImage: "arrow.right") { send([0x1b, 0x5b, 0x43]) }   // ESC [ C
                key(nil, systemImage: "photo") { pasteImage() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.thinMaterial)
    }

    private func send(_ bytes: [UInt8]) {
        TouchRemoteTerminalManager.shared.sendBytes(bytes, to: sessionId)
    }

    /// Paste the clipboard's image (e.g. a screenshot) through to the worker's
    /// Claude. No-op with a warning haptic if the clipboard holds no image.
    private func pasteImage() {
        guard let image = UIPasteboard.general.image else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        TouchRemoteTerminalManager.shared.sendImage(image, to: sessionId)
    }

    @ViewBuilder
    private func key(_ label: String?, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let label {
                    Text(label).font(.system(.callout, design: .monospaced))
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
            }
            .frame(minWidth: 44, minHeight: 34)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
