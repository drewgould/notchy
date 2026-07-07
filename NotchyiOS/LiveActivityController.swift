import Foundation
import ActivityKit

/// Starts / updates / ends the Notchy Live Activity from the viewer store's
/// aggregate status. One activity at a time reflects "something on your Macs
/// needs you / is working / just finished"; it ends when everything goes idle.
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<NotchyActivityAttributes>?

    private init() {}

    /// Recompute from the store and reconcile the live activity. Call on main.
    func refresh() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let store = RemoteViewerStore.shared

        guard let state = contentState(store) else {
            endActivity()
            return
        }
        if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            do {
                activity = try Activity.request(
                    attributes: NotchyActivityAttributes(),
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
            } catch {
                print("[liveactivity] request failed: \(error)")
            }
        }
    }

    private func endActivity() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// nil ⇒ idle ⇒ no activity.
    private func contentState(_ store: RemoteViewerStore) -> NotchyActivityAttributes.ContentState? {
        let session = store.representativeSession
        switch store.aggregateStatus {
        case .idle:
            return nil
        case .attention:
            return .init(kind: .attention,
                         title: session?.projectName ?? "Waiting for input",
                         detail: session?.pendingQuestion ?? "Claude needs your input")
        case .working:
            return .init(kind: .working,
                         title: session?.projectName ?? "Working",
                         detail: session?.activityLine ?? "Claude is working…")
        case .done:
            return .init(kind: .done,
                         title: session?.projectName ?? "Done",
                         detail: "Task completed")
        }
    }
}
