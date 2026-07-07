import ActivityKit

/// Live Activity payload shared by the iOS app (which starts/updates it) and the
/// widget extension (which renders it). Mirrors the notch's status vocabulary.
struct NotchyActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public enum Kind: String, Codable {
            case working    // Claude is working (spinner)
            case attention  // waiting for input (needs you)
            case done       // task just completed
        }
        public var kind: Kind
        /// Primary line — usually the session/project name, or a count.
        public var title: String
        /// Secondary line — activity spinner text or the pending question.
        public var detail: String?

        public init(kind: Kind, title: String, detail: String? = nil) {
            self.kind = kind
            self.title = title
            self.detail = detail
        }
    }

    /// Static across the activity's life.
    public var appName: String

    public init(appName: String = "Notchy") {
        self.appName = appName
    }
}
