import Foundation
import CryptoKit

/// Chunked file transfer, viewer → worker.
///
/// A local drop types the dropped file's path (see `ClickThroughTerminalView.
/// performDragOperation`) because Claude runs on the same Mac. A drop on a
/// *viewer* can't: the worker has no file at that path, and on a Mac-to-Mac
/// viewer the path may resolve to a different real file — silently feeding
/// Claude the wrong bytes. So the bytes travel, the worker writes them to a
/// temp dir, and the worker types the path of what *it* wrote. The drop then
/// bottoms out exactly where a local drop does.
///
/// Frames are chunked so the wire keeps its ≤4 MB frame cap regardless of file
/// size, and so neither end has to hold a whole file in memory — the sender
/// streams off disk, the receiver streams onto it.
///
/// Payload layouts (all binary):
///
///     fileBegin  [16B sessionId][16B transferId][8B totalLength BE]
///                [2B nameLength BE][name UTF-8]
///     fileChunk  [16B transferId][4B sequence BE][slice]
///     fileEnd    [16B transferId][32B SHA-256 of the whole file]
///     fileAbort  [16B transferId]
///     fileResult [16B transferId][1B ok][reason UTF-8]   (worker → viewer)
nonisolated enum FileTransferCodec {
    /// Sized to sit far under `FrameCodec.maxFrameLength` (leaving room for the
    /// header and AES-GCM overhead) while still ticking progress often enough to
    /// look live on a slow link.
    static let chunkSize = 256 * 1024

    /// Defensive ceiling on one transfer. A drop is meant to hand Claude a file
    /// to read; past this it's a mis-drag, and we'd rather fail loudly than
    /// quietly stream a disk image across the room.
    static let maxFileBytes: UInt64 = 1024 * 1024 * 1024

    /// Names are bounded so a hostile/blundering peer can't push a 64 KB name
    /// through; the receiver sanitizes separately.
    static let maxNameBytes = 1024

    // MARK: - Encoding

    static func encodeBegin(sessionId: UUID, transferId: UUID, totalLength: UInt64, name: String) -> Data? {
        let nameBytes = Data(name.utf8)
        guard nameBytes.count <= maxNameBytes else { return nil }
        var payload = Data(capacity: 42 + nameBytes.count)
        payload.append(uuidBytes(sessionId))
        payload.append(uuidBytes(transferId))
        withUnsafeBytes(of: totalLength.bigEndian) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(nameBytes.count).bigEndian) { payload.append(contentsOf: $0) }
        payload.append(nameBytes)
        return FrameCodec.frame(type: .fileBegin, payload: payload)
    }

    static func encodeChunk(transferId: UUID, sequence: UInt32, slice: Data) -> Data {
        var payload = Data(capacity: 20 + slice.count)
        payload.append(uuidBytes(transferId))
        withUnsafeBytes(of: sequence.bigEndian) { payload.append(contentsOf: $0) }
        payload.append(slice)
        return FrameCodec.frame(type: .fileChunk, payload: payload)
    }

    static func encodeEnd(transferId: UUID, digest: Data) -> Data {
        var payload = uuidBytes(transferId)
        payload.append(digest)
        return FrameCodec.frame(type: .fileEnd, payload: payload)
    }

    static func encodeAbort(transferId: UUID) -> Data {
        FrameCodec.frame(type: .fileAbort, payload: uuidBytes(transferId))
    }

    static func encodeResult(transferId: UUID, ok: Bool, reason: String?) -> Data {
        var payload = uuidBytes(transferId)
        payload.append(ok ? 1 : 0)
        if let reason {
            payload.append(Data(reason.utf8.prefix(maxNameBytes)))
        }
        return FrameCodec.frame(type: .fileResult, payload: payload)
    }

    // MARK: - Parsing

    struct Begin {
        let sessionId: UUID
        let transferId: UUID
        let totalLength: UInt64
        let name: String
    }

    static func parseBegin(_ payload: Data) -> Begin? {
        guard payload.count >= 42 else { return nil }
        let base = payload.startIndex
        guard let sessionId = uuid(payload, at: base),
              let transferId = uuid(payload, at: base + 16) else { return nil }
        let totalLength = payload[(base + 32)..<(base + 40)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let nameLength = Int(payload[(base + 40)..<(base + 42)].reduce(UInt16(0)) { ($0 << 8) | UInt16($1) })
        guard nameLength > 0, payload.count == 42 + nameLength,
              let name = String(data: payload[(base + 42)...], encoding: .utf8) else { return nil }
        return Begin(sessionId: sessionId, transferId: transferId, totalLength: totalLength, name: name)
    }

    static func parseChunk(_ payload: Data) -> (transferId: UUID, sequence: UInt32, slice: Data)? {
        guard payload.count >= 20, let transferId = uuid(payload, at: payload.startIndex) else { return nil }
        let seqStart = payload.startIndex + 16
        let sequence = payload[seqStart..<(seqStart + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return (transferId, sequence, payload[(seqStart + 4)...])
    }

    static func parseEnd(_ payload: Data) -> (transferId: UUID, digest: Data)? {
        guard payload.count == 48, let transferId = uuid(payload, at: payload.startIndex) else { return nil }
        return (transferId, payload[(payload.startIndex + 16)...])
    }

    static func parseAbort(_ payload: Data) -> UUID? {
        guard payload.count == 16 else { return nil }
        return uuid(payload, at: payload.startIndex)
    }

    static func parseResult(_ payload: Data) -> (transferId: UUID, ok: Bool, reason: String?)? {
        guard payload.count >= 17, let transferId = uuid(payload, at: payload.startIndex) else { return nil }
        let ok = payload[payload.startIndex + 16] == 1
        let rest = payload[(payload.startIndex + 17)...]
        let reason = rest.isEmpty ? nil : String(data: rest, encoding: .utf8)
        return (transferId, ok, reason)
    }

    // MARK: - Helpers

    static func uuidBytes(_ id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    private static func uuid(_ data: Data, at offset: Int) -> UUID? {
        guard offset + 16 <= data.endIndex else { return nil }
        let raw = data[offset..<(offset + 16)].withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        return UUID(uuid: raw)
    }

    /// Strip a peer-supplied name down to something safe to join onto a
    /// directory *and* to type into a tty. A name like `../../.zshrc` must not
    /// escape the drop dir — each transfer gets its own subdirectory anyway, so
    /// collisions can't clobber.
    ///
    /// Control characters matter as much as separators here: the worker types
    /// this path into a PTY, where `\n` and `\r` are Return, not text. A file
    /// legitimately named `notes\nrm -rf ~.txt` (legal on macOS) would submit
    /// the prompt line mid-path. Quoting can't save that — the tty sees the byte
    /// long before any shell parses it — so the character never survives to the
    /// terminal. Falls back to a generic name rather than failing the transfer.
    static func sanitize(name: String) -> String {
        let leaf = (name as NSString).lastPathComponent
        let cleaned = String(leaf.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || CharacterSet.controlCharacters.contains(scalar) {
                return "_"
            }
            return Character(scalar)
        })
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "dropped-file"
        }
        // Guard against a name so long the filesystem rejects the write.
        if cleaned.utf8.count > 200 {
            let ext = (cleaned as NSString).pathExtension
            let stem = String((cleaned as NSString).deletingPathExtension.prefix(150))
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        return cleaned
    }
}

// MARK: - Sender (viewer side)

/// Streams one file off disk into `fileBegin`/`fileChunk`/`fileEnd` frames.
///
/// Chunks are paced by the transport: the next slice is only read once the
/// previous frame has been handed to the network stack, so a big file can't
/// balloon `NWConnection`'s send queue. Frames ride a single ordered TCP
/// stream, so files dropped together arrive in the order they were enqueued and
/// the worker types their paths in that same order — no batch bookkeeping.
final class FileTransferSender {
    private let io = DispatchQueue(label: "com.notchy.filetransfer.send", qos: .utility)

    /// `send` is invoked on the main queue (peer sends are main-thread-only) and
    /// must call its completion once the transport has taken the frame, reporting
    /// whether it did. `progress` reports bytes sent / total and `finished`
    /// reports success, both on the main queue.
    func send(
        fileURL: URL,
        name: String,
        sessionId: UUID,
        transferId: UUID = UUID(),
        send: @escaping (Data, @escaping (Bool) -> Void) -> Void,
        progress: @escaping (UInt64, UInt64) -> Void,
        finished: @escaping (Bool) -> Void
    ) {
        io.async {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                DispatchQueue.main.async { finished(false) }
                return
            }
            defer { try? handle.close() }

            // Ask the handle rather than the file attributes: same answer, no
            // NSNumber bridging, and it's the length we'll actually read.
            guard let total = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil,
                  total <= FileTransferCodec.maxFileBytes,
                  let begin = FileTransferCodec.encodeBegin(
                      sessionId: sessionId,
                      transferId: transferId,
                      totalLength: total,
                      name: name
                  )
            else {
                DispatchQueue.main.async { finished(false) }
                return
            }

            /// Hand one frame to the transport and wait for it to be taken —
            /// this is the backpressure that keeps a big file from piling up in
            /// the send queue. Returns false once the link is gone.
            func deliver(_ frame: Data) -> Bool {
                let group = DispatchGroup()
                var delivered = false
                group.enter()
                DispatchQueue.main.async {
                    send(frame) { ok in
                        delivered = ok
                        group.leave()
                    }
                }
                group.wait()
                return delivered
            }

            guard deliver(begin) else {
                DispatchQueue.main.async { finished(false) }
                return
            }

            var hasher = SHA256()
            var sequence: UInt32 = 0
            var sent: UInt64 = 0

            while sent < total {
                guard let slice = try? handle.read(upToCount: FileTransferCodec.chunkSize), !slice.isEmpty else {
                    break  // file shrank under us — the length guard below catches it
                }
                hasher.update(data: slice)
                sent += UInt64(slice.count)

                let frame = FileTransferCodec.encodeChunk(transferId: transferId, sequence: sequence, slice: slice)
                sequence &+= 1

                // Peer vanished mid-transfer: stop reading rather than stream the
                // rest of the file into a dead connection. The worker discards its
                // partial file when the peer drops, so no abort frame is needed.
                guard deliver(frame) else {
                    DispatchQueue.main.async { finished(false) }
                    return
                }

                let soFar = sent
                DispatchQueue.main.async { progress(soFar, total) }
            }

            // The file changed size under us mid-read — the worker would reject
            // the length anyway, so abort rather than send a bad fileEnd.
            guard sent == total else {
                _ = deliver(FileTransferCodec.encodeAbort(transferId: transferId))
                DispatchQueue.main.async { finished(false) }
                return
            }

            let digest = Data(hasher.finalize())
            let ok = deliver(FileTransferCodec.encodeEnd(transferId: transferId, digest: digest))
            DispatchQueue.main.async { finished(ok) }
        }
    }
}

// MARK: - Drop coordinator (viewer side)

/// What a viewer's drop handler calls. Owns the queue of files a drop produced,
/// streams them to the worker, and publishes progress for the UI.
@MainActor
@Observable
final class FileDropCoordinator {
    static let shared = FileDropCoordinator()

    /// Name of the file currently streaming, or nil when idle.
    private(set) var activeName: String?
    private(set) var sentBytes: UInt64 = 0
    private(set) var totalBytes: UInt64 = 0
    /// Files accepted by this drop but not yet started.
    private(set) var queuedCount = 0
    /// Set when a drop is rejected or fails, for the viewer to surface. Clears
    /// itself after a few seconds, and when the next drop starts.
    private(set) var lastError: String?

    /// One sender per worker, because a sender's serial IO queue is exactly what
    /// orders a drop's files — and order only has to hold *within* a Mac, where
    /// the paths get typed onto one prompt line. Sharing a single sender across
    /// every peer would also make a 1 GB drop to one Mac block a 2 KB drop to
    /// another. One small object per paired Mac, so no eviction needed.
    private var senders: [UUID: FileTransferSender] = [:]

    /// Names of transfers awaiting a worker verdict, so a `fileResult` can say
    /// which file it's about.
    private var pendingNames: [UUID: String] = [:]

    /// Generation counter so a stale auto-dismiss can't wipe a newer error.
    private var errorGeneration = 0

    private func sender(for machineId: UUID) -> FileTransferSender {
        if let existing = senders[machineId] { return existing }
        let created = FileTransferSender()
        senders[machineId] = created
        return created
    }

    var fractionComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(sentBytes) / Double(totalBytes))
    }

    /// Accept a drop of `urls` for a remote session. Returns false if nothing in
    /// the drop was sendable, so the caller can signal a failed drop.
    @discardableResult
    func drop(_ urls: [URL], sessionId: UUID, machineId: UUID) -> Bool {
        // (url, weHoldItsSecurityScope). A Files-app drop on iOS hands over a
        // security-scoped URL that can't even be stat'd until the scope is open,
        // so the scope has to start *before* the readability probe — otherwise a
        // perfectly good file reads as "isn't readable" and never sends. Handed
        // to `enqueue`, which releases it when the send finishes.
        var sendable: [(url: URL, scoped: Bool)] = []
        var rejection: String?

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            if let reason = Self.rejectionReason(for: url) {
                rejection = reason
                if scoped { url.stopAccessingSecurityScopedResource() }
                continue
            }
            sendable.append((url, scoped))
        }
        setError(rejection)

        guard !sendable.isEmpty else { return false }
        queuedCount += sendable.count
        for item in sendable {
            enqueue(item.url, scoped: item.scoped, sessionId: sessionId, machineId: machineId)
        }
        return true
    }

    /// Show a rejection and let it fade — an error that sticks around until the
    /// next drop reads as a permanent broken state.
    private func setError(_ message: String?) {
        errorGeneration &+= 1
        lastError = message
        guard message != nil else { return }
        let generation = errorGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.errorGeneration == generation else { return }
            self.lastError = nil
        }
    }

    /// Why this URL can't ride the wire, or nil if it can.
    private static func rejectionReason(for url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return "\(url.lastPathComponent) isn't readable"
        }
        // A folder would have to be archived to travel. A local drop can just
        // type its path; a mirror can't. Reject rather than half-send.
        if isDirectory.boolValue {
            return "Can't drop folders on a remote session"
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        if let size, UInt64(size) > FileTransferCodec.maxFileBytes {
            return "\(url.lastPathComponent) is too large to send"
        }
        return nil
    }

    /// `scoped` is whether `drop` opened a security scope we now own and must
    /// close once the bytes are off disk.
    private func enqueue(_ url: URL, scoped: Bool, sessionId: UUID, machineId: UUID) {
        let name = url.lastPathComponent
        let transferId = UUID()
        pendingNames[transferId] = name

        sender(for: machineId).send(
            fileURL: url,
            name: name,
            sessionId: sessionId,
            transferId: transferId,
            send: { frame, done in
                RemotePeerManager.shared.sendFileFrame(machineId: machineId, frame: frame, completion: done)
            },
            progress: { [weak self] sent, total in
                guard let self else { return }
                self.activeName = name
                self.sentBytes = sent
                self.totalBytes = total
            },
            finished: { [weak self] ok in
                if scoped { url.stopAccessingSecurityScopedResource() }
                guard let self else { return }
                // Sending is only half the story — the worker still has to land it
                // and type the path. `handleResult` closes that half out, and a
                // send that never got off this device won't get one, so drop the
                // pending entry here.
                if !ok {
                    self.pendingNames.removeValue(forKey: transferId)
                    self.setError("Couldn't send \(name)")
                    print("[remote] drop send failed for \(name)")
                }
                self.finishOne()
            }
        )
    }

    /// A worker verdict for one transfer. Success is silent — the path appearing
    /// on the prompt line is the feedback.
    func handleResult(transferId: UUID, ok: Bool, reason: String?) {
        guard let name = pendingNames.removeValue(forKey: transferId) else { return }
        guard !ok else { return }
        setError(reason.map { "\(name): \($0)" } ?? "The Mac couldn't take \(name)")
        print("[remote] worker rejected drop \(name): \(reason ?? "unknown")")
    }

    private func finishOne() {
        queuedCount = max(0, queuedCount - 1)
        guard queuedCount == 0 else { return }
        activeName = nil
        sentBytes = 0
        totalBytes = 0
    }
}

// MARK: - Receiver (worker side)

/// Reassembles inbound transfers onto disk and hands the finished path to the
/// terminal. Streams straight to a `FileHandle` — a 1 GB drop costs one chunk
/// of memory, not a gigabyte.
///
/// All state is touched only on `io`; frames arrive on main and hop here.
final class FileTransferReceiver {
    static let shared = FileTransferReceiver()

    private let io = DispatchQueue(label: "com.notchy.filetransfer.receive", qos: .utility)

    private struct Transfer {
        let machineId: UUID
        let sessionId: UUID
        let directory: URL
        let destination: URL
        let totalLength: UInt64
        var handle: FileHandle
        var hasher = SHA256()
        var received: UInt64 = 0
        var nextSequence: UInt32 = 0
    }

    private var transfers: [UUID: Transfer] = [:]

    /// Cap concurrent in-flight transfers per peer so a misbehaving viewer can't
    /// pin unbounded open file handles on the worker.
    private static let maxConcurrentPerPeer = 8

    /// Drops land here, one subdirectory per transfer so identical names from
    /// different drops can't collide. Left in place after the drop: Claude reads
    /// the path *after* the user submits the line, so cleaning up on completion
    /// would pull the file out from under it.
    private static var dropRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Notchy-drops", isDirectory: true)
    }

    // MARK: Frame handling

    func begin(_ begin: FileTransferCodec.Begin, from machineId: UUID) {
        io.async {
            guard begin.totalLength <= FileTransferCodec.maxFileBytes else {
                self.report(begin.transferId, to: machineId, ok: false, reason: "file is too large")
                return
            }
            guard self.transfers[begin.transferId] == nil else { return }
            let inFlight = self.transfers.values.filter { $0.machineId == machineId }.count
            guard inFlight < Self.maxConcurrentPerPeer else {
                self.report(begin.transferId, to: machineId, ok: false, reason: "too many transfers at once")
                return
            }

            let name = FileTransferCodec.sanitize(name: begin.name)
            let directory = Self.dropRoot.appendingPathComponent(begin.transferId.uuidString, isDirectory: true)
            let destination = directory.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                let handle = try FileHandle(forWritingTo: destination)
                self.transfers[begin.transferId] = Transfer(
                    machineId: machineId,
                    sessionId: begin.sessionId,
                    directory: directory,
                    destination: destination,
                    totalLength: begin.totalLength,
                    handle: handle
                )
                print("[remote] receiving drop '\(name)' (\(begin.totalLength)B) for session \(begin.sessionId)")
            } catch {
                print("[remote] can't open drop destination for '\(name)': \(error)")
                try? FileManager.default.removeItem(at: directory)
                self.report(begin.transferId, to: machineId, ok: false, reason: "the Mac couldn't open a file to write")
            }
        }
    }

    func chunk(transferId: UUID, sequence: UInt32, slice: Data) {
        io.async {
            guard var transfer = self.transfers[transferId] else { return }
            // Frames ride one ordered stream, so a gap means a bug or a hostile
            // peer, not reordering — either way the file would be wrong.
            guard sequence == transfer.nextSequence else {
                self.fail(transferId, "arrived out of order")
                return
            }
            guard transfer.received + UInt64(slice.count) <= transfer.totalLength else {
                self.fail(transferId, "sent more data than it declared")
                return
            }
            do {
                try transfer.handle.write(contentsOf: slice)
            } catch {
                self.fail(transferId, "the Mac couldn't write it (disk full?)")
                return
            }
            transfer.hasher.update(data: slice)
            transfer.received += UInt64(slice.count)
            transfer.nextSequence &+= 1
            self.transfers[transferId] = transfer
        }
    }

    func end(transferId: UUID, digest: Data) {
        io.async {
            guard let transfer = self.transfers[transferId] else { return }
            try? transfer.handle.close()

            guard transfer.received == transfer.totalLength else {
                self.fail(transferId, "transfer was cut short")
                return
            }
            // The transport already authenticates every frame; this catches a
            // reassembly bug on our side, not an attacker.
            guard Data(transfer.hasher.finalize()) == digest else {
                self.fail(transferId, "arrived corrupted")
                return
            }

            self.transfers.removeValue(forKey: transferId)
            let path = transfer.destination.path
            print("[remote] drop complete: \(path)")
            DispatchQueue.main.async {
                // The tab may have closed while the bytes were in flight — only
                // a path that actually reached a terminal counts as a success.
                let typed = RemoteRuntime.host?.insertDroppedFilePath(to: transfer.sessionId, path: path) ?? false
                if !typed {
                    try? FileManager.default.removeItem(at: transfer.directory)
                }
                self.report(transferId, to: transfer.machineId, ok: typed,
                            reason: typed ? nil : "that session isn't open anymore")
            }
        }
    }

    func abort(transferId: UUID) {
        // Viewer-initiated: it already knows, so no result frame.
        io.async { self.discard(transferId) }
    }

    /// A peer vanished mid-transfer — its partial files are unreachable now, and
    /// there's nobody left to tell.
    func cancelTransfers(from machineId: UUID) {
        io.async {
            for id in self.transfers.filter({ $0.value.machineId == machineId }).keys {
                self.discard(id)
            }
        }
    }

    /// Caller must be on `io`. Discards the partial file and tells the viewer why,
    /// so a failed drop surfaces there instead of only in this Mac's log.
    private func fail(_ transferId: UUID, _ reason: String) {
        guard let transfer = transfers.removeValue(forKey: transferId) else { return }
        try? transfer.handle.close()
        try? FileManager.default.removeItem(at: transfer.directory)
        print("[remote] drop \(transferId) failed: \(reason)")
        report(transferId, to: transfer.machineId, ok: false, reason: reason)
    }

    /// Peer sends are main-thread-only, hence the hop.
    private func report(_ transferId: UUID, to machineId: UUID, ok: Bool, reason: String?) {
        let frame = FileTransferCodec.encodeResult(transferId: transferId, ok: ok, reason: reason)
        DispatchQueue.main.async {
            RemotePeerManager.shared.sendFileFrame(machineId: machineId, frame: frame) { _ in }
        }
    }

    /// Caller must be on `io`.
    private func discard(_ transferId: UUID) {
        guard let transfer = transfers.removeValue(forKey: transferId) else { return }
        try? transfer.handle.close()
        try? FileManager.default.removeItem(at: transfer.directory)
    }
}
