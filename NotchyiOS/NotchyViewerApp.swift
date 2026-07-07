import SwiftUI

/// iOS entry point for the Notchy remote viewer. This is a bring-up stub —
/// the real session-list / terminal UI lands next. Its only job right now is
/// to give the iOS target an `@main` so the shared networking/model core
/// (the `Shared/` folder) is compiled against the iOS SDK.
@main
struct NotchyViewerApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 48))
                Text("Notchy")
                    .font(.title.bold())
                Text("Remote viewer — bring-up")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
