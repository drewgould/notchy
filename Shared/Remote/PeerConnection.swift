import Foundation
import Network
import CryptoKit

/// One TCP connection to another Notchy instance. Owns the framing; state
/// callbacks and decoded frames are delivered on the network queue — the
/// owner (RemotePeerManager) hops to main as needed.
nonisolated final class PeerConnection {
    enum Role {
        /// We dialed them (from a Bonjour browse result).
        case outbound
        /// They dialed us (accepted by our listener).
        case inbound
    }

    let connection: NWConnection
    let role: Role
    /// Set once the peer's `hello` arrives (inbound) or known from the browse
    /// result (outbound, then confirmed by `hello`).
    var remoteMachineId: UUID?
    var remoteName: String?
    /// App-level liveness: bumped on every received frame.
    var lastReceivedAt = Date()

    var onFrame: ((PeerConnection, RemoteMessageType, Data) -> Void)?
    var onFailed: ((PeerConnection) -> Void)?
    var onReady: ((PeerConnection) -> Void)?

    private var innerDecoder = FrameDecoder()
    private var rxBuffer = Data()
    private var isCancelled = false

    /// Per-peer AES-GCM key, set once trust is established. nil ⇒ plaintext (as
    /// for iCloud-trusted Mac-to-Mac). Read on both main (send) and the network
    /// queue (receive), so guarded by a lock.
    private let keyLock = NSLock()
    private var _encryptionKey: SymmetricKey?
    var encryptionKey: SymmetricKey? {
        get { keyLock.lock(); defer { keyLock.unlock() }; return _encryptionKey }
        set { keyLock.lock(); _encryptionKey = newValue; keyLock.unlock() }
    }

    /// Encrypted units add AES-GCM overhead over the ≤1 MB inner frame cap.
    private static let maxOuterLength = 2 * 1024 * 1024

    init(connection: NWConnection, role: Role, remoteMachineId: UUID? = nil) {
        self.connection = connection
        self.role = role
        self.remoteMachineId = remoteMachineId
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?(self)
                self.receiveLoop()
            case .failed, .cancelled:
                self.fail()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ frame: Data) {
        guard let unit = Self.wrap(frame, key: encryptionKey) else { return }
        connection.send(content: unit, completion: .contentProcessed { _ in })
    }

    /// Wrap one frame in the transport envelope: `[UInt32 len][flag][body]`,
    /// where flag 1 ⇒ body is AES-GCM(frame) and flag 0 ⇒ body is the frame
    /// verbatim. Returns nil (drop) rather than ever downgrading an encrypted
    /// peer to plaintext.
    private static func wrap(_ frame: Data, key: SymmetricKey?) -> Data? {
        let flag: UInt8
        let body: Data
        if let key {
            guard let sealed = try? AES.GCM.seal(frame, using: key).combined else { return nil }
            body = sealed
            flag = 1
        } else {
            body = frame
            flag = 0
        }
        var out = Data(capacity: body.count + 5)
        withUnsafeBytes(of: UInt32(body.count + 1).bigEndian) { out.append(contentsOf: $0) }
        out.append(flag)
        out.append(body)
        return out
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onFrame = nil
        onFailed = nil
        onReady = nil
        connection.cancel()
    }

    private func fail() {
        guard !isCancelled else { return }
        onFailed?(self)
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.isCancelled else { return }
            if let data, !data.isEmpty {
                self.lastReceivedAt = Date()
                guard self.ingest(data) else { return }  // ingest failed ⇒ already dropped
            }
            if isComplete || error != nil {
                self.fail()
                return
            }
            self.receiveLoop()
        }
    }

    /// Parse transport envelopes out of the byte stream, decrypt as flagged, and
    /// deliver the inner frames. Returns false (and fails the connection) on a
    /// corrupt or undecryptable stream — the manager then redials.
    private func ingest(_ data: Data) -> Bool {
        rxBuffer.append(data)
        while rxBuffer.count >= 4 {
            let len = rxBuffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard len >= 1, len <= UInt32(Self.maxOuterLength) else { fail(); return false }
            let total = 4 + Int(len)
            guard rxBuffer.count >= total else { break }
            let flag = rxBuffer[rxBuffer.startIndex + 4]
            let body = rxBuffer.subdata(in: (rxBuffer.startIndex + 5)..<(rxBuffer.startIndex + total))
            rxBuffer.removeFirst(total)

            let innerBytes: Data
            if flag == 1 {
                guard let key = encryptionKey,
                      let box = try? AES.GCM.SealedBox(combined: body),
                      let opened = try? AES.GCM.open(box, using: key) else { fail(); return false }
                innerBytes = opened
            } else {
                innerBytes = body
            }
            innerDecoder.append(innerBytes)
            do {
                while let (type, payload) = try innerDecoder.next() {
                    onFrame?(self, type, payload)
                }
            } catch {
                fail()
                return false
            }
        }
        return true
    }
}
