import Foundation

/// Worker-side fan-out of raw PTY output to subscribed viewer Macs.
///
/// Every local terminal's output is appended to a per-session ring buffer
/// (for backfill when a viewer subscribes mid-session) and forwarded live to
/// current subscribers. With zero subscribers the only cost is the buffer
/// append.
final class TerminalMirrorHub {
    static let shared = TerminalMirrorHub()

    private struct MirrorState {
        var ringBuffer = Data()
        /// machineIds of viewers currently mirroring this session.
        var subscribers: Set<UUID> = []
    }

    private var mirrors: [UUID: MirrorState] = [:]
    private static let ringCapacity = 256 * 1024

    /// Called from ClickThroughTerminalView.dataReceived (main thread) with
    /// every PTY output burst.
    func publish(sessionId: UUID, bytes: Data) {
        guard SettingsManager.shared.remoteTabsEnabled else { return }
        var mirror = mirrors[sessionId] ?? MirrorState()
        mirror.ringBuffer.append(bytes)
        if mirror.ringBuffer.count > Self.ringCapacity {
            mirror.ringBuffer = Data(mirror.ringBuffer.suffix(Self.ringCapacity))
        }
        mirrors[sessionId] = mirror
        RemotePeerManager.shared.sendTermData(to: mirror.subscribers, sessionId: sessionId, bytes: bytes)
    }

    /// Register a viewer. Returns the PTY dims plus a snapshot payload
    /// (full-reset + backfill), or nil when no terminal exists for the session.
    /// Starting mid-escape-sequence can garble a few cells momentarily —
    /// acceptable since Claude's TUI redraws the whole screen constantly.
    func subscribe(machineId: UUID, sessionId: UUID) -> (cols: Int, rows: Int, snapshot: Data)? {
        guard let size = TerminalManager.shared.terminalSize(for: sessionId) else { return nil }
        var mirror = mirrors[sessionId] ?? MirrorState()
        mirror.subscribers.insert(machineId)
        mirrors[sessionId] = mirror
        var snapshot = Data("\u{1b}c".utf8)  // RIS: reset the viewer before backfill
        snapshot.append(mirror.ringBuffer)
        return (size.cols, size.rows, snapshot)
    }

    func unsubscribe(machineId: UUID, sessionId: UUID) {
        mirrors[sessionId]?.subscribers.remove(machineId)
    }

    /// Drop a departing viewer from every session and report which sessions it
    /// left with no viewers remaining — the caller restores those to their
    /// natural (window-derived) grid, since a viewer that was driving the size
    /// is now gone. The clean-unsubscribe path does this per session; a dropped
    /// connection (backgrounded/killed iPad) comes through here instead, and
    /// without this the worker's PTY stays shrunk to the viewer's grid forever.
    func unsubscribeAll(machineId: UUID) -> [UUID] {
        var nowUnwatched: [UUID] = []
        for sessionId in mirrors.keys {
            guard mirrors[sessionId]?.subscribers.remove(machineId) != nil else { continue }
            if mirrors[sessionId]?.subscribers.isEmpty == true {
                nowUnwatched.append(sessionId)
            }
        }
        return nowUnwatched
    }

    func subscribers(for sessionId: UUID) -> Set<UUID> {
        mirrors[sessionId]?.subscribers ?? []
    }

    /// The PTY died (session restart/close on this Mac) — tell viewers and
    /// drop the buffer.
    func sessionEnded(_ sessionId: UUID) {
        guard let mirror = mirrors.removeValue(forKey: sessionId) else { return }
        RemotePeerManager.shared.broadcastSessionClosed(sessionId, to: mirror.subscribers)
    }
}
