import Foundation
import Network

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

    private var decoder = FrameDecoder()
    private var isCancelled = false

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
        connection.send(content: frame, completion: .contentProcessed { _ in })
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
                self.decoder.append(data)
                do {
                    while let (type, payload) = try self.decoder.next() {
                        self.onFrame?(self, type, payload)
                    }
                } catch {
                    // Corrupt stream — drop the connection; the manager redials.
                    self.fail()
                    return
                }
            }
            if isComplete || error != nil {
                self.fail()
                return
            }
            self.receiveLoop()
        }
    }
}
