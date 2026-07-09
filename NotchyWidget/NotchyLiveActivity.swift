import WidgetKit
import SwiftUI
import ActivityKit

/// Live Activity rendering for Notchy's aggregate remote-session status —
/// Lock Screen banner plus the three Dynamic Island presentations. Uses the
/// same spinner / warning / checkmark vocabulary as the Mac notch pill.
struct NotchyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NotchyActivityAttributes.self) { context in
            lockScreen(context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusGlyph(kind: context.state.kind).font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        if let detail = context.state.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } compactLeading: {
                StatusGlyph(kind: context.state.kind)
            } compactTrailing: {
                if context.state.kind == .working {
                    Image(systemName: "waveform").symbolEffect(.variableColor)
                }
            } minimal: {
                StatusGlyph(kind: context.state.kind)
            }
        }
    }

    private func lockScreen(_ state: NotchyActivityAttributes.ContentState) -> some View {
        HStack(spacing: 12) {
            StatusGlyph(kind: state.kind).font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.headline).lineLimit(1)
                if let detail = state.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
    }
}

/// The status icon shared by every presentation.
struct StatusGlyph: View {
    let kind: NotchyActivityAttributes.ContentState.Kind

    var body: some View {
        switch kind {
        case .working:
            Image(systemName: "gearshape.2.fill")
                .symbolEffect(.pulse)
                .foregroundStyle(.yellow)
        case .attention:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
