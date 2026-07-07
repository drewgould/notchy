import Foundation
import Network

/// Live transport between Notchy instances on the LAN: advertises this Mac
/// via Bonjour (`_notchy._tcp`, service name = machineId), auto-connects to
/// every discovered peer, and shuttles protocol frames.
///
/// Plaintext TCP on a trusted LAN; the trust anchor is the iCloud-synced
/// machine list — a `hello` from a machineId with no iCloud manifest is
/// rejected. (Upgrade path if ever needed: NWParameters(tls:) with a
/// pre-shared key synced through iCloud.)
///
/// Threading: all state lives on the main thread. PeerConnection delivers
/// callbacks on the network queue; every handler immediately hops to main.
final class RemotePeerManager {
    static let shared = RemotePeerManager()
    static let serviceType = "_notchy._tcp"
    static let protocolVersion = 1

    private static let networkQueue = DispatchQueue(label: "com.notchy.network")

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var isRunning = false

    /// Handshake-complete peers by machineId.
    private var peers: [UUID: PeerConnection] = [:]
    /// Connections that haven't completed the hello exchange.
    private var pendingConnections: [ObjectIdentifier: PeerConnection] = [:]
    /// Latest Bonjour endpoint per discovered machineId.
    private var discoveredEndpoints: [UUID: NWEndpoint] = [:]
    /// Redial backoff: earliest next attempt and current delay per machine.
    private var nextDialAttempt: [UUID: Date] = [:]
    private var dialDelay: [UUID: TimeInterval] = [:]

    private var maintenanceTimer: Timer?
    private var lastPingAt = Date.distantPast
    private var sessionListDebounce: Timer?
    /// Sessions with unsent live-state changes, flushed on a short debounce.
    private var dirtySessionIds: Set<UUID> = []
    private var statusDebounce: Timer?
    /// Completion handlers for in-flight network create requests. Called with
    /// nil on timeout so the caller can fall back to the iCloud queue.
    private var createResponseHandlers: [UUID: (CreateSessionResponseMessage?) -> Void] = [:]

    private static let maintenanceInterval: TimeInterval = 5
    private static let pingInterval: TimeInterval = 10
    private static let peerTimeout: TimeInterval = 30
    private static let maxDialDelay: TimeInterval = 30

    // MARK: - Lifecycle

    func start() {
        guard SettingsManager.shared.remoteTabsEnabled, !isRunning else { return }
        isRunning = true
        startListener()
        startBrowser()
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: Self.maintenanceInterval, repeats: true) { [weak self] _ in
            self?.maintain()
        }
    }

    func stop() {
        isRunning = false
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        sessionListDebounce?.invalidate()
        sessionListDebounce = nil
        statusDebounce?.invalidate()
        statusDebounce = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        for peer in peers.values { peer.cancel() }
        for peer in pendingConnections.values { peer.cancel() }
        let machineIds = Array(peers.keys)
        peers = [:]
        pendingConnections = [:]
        discoveredEndpoints = [:]
        for id in machineIds { RemoteRuntime.sink?.setPeerOnline(id, false) }
    }

    private static func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.noDelay = true  // keystroke latency matters
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }

    private func startListener() {
        guard let listener = try? NWListener(using: Self.makeParameters()) else {
            print("[remote] failed to create listener")
            return
        }
        listener.service = NWListener.Service(
            name: MachineIdentity.id.uuidString,
            type: Self.serviceType
        )
        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async {
                self?.adopt(connection: connection, role: .inbound, machineId: nil)
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[remote] listener failed: \(error)")
            }
        }
        listener.start(queue: Self.networkQueue)
        self.listener = listener
    }

    private func startBrowser() {
        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: Self.makeParameters()
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints: [(UUID, NWEndpoint)] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint,
                      let machineId = UUID(uuidString: name) else { return nil }
                return (machineId, result.endpoint)
            }
            DispatchQueue.main.async {
                guard let self, self.isRunning else { return }
                self.discoveredEndpoints = Dictionary(endpoints) { _, latest in latest }
                self.discoveredEndpoints.removeValue(forKey: MachineIdentity.id)
                self.ensureConnections()
            }
        }
        browser.start(queue: Self.networkQueue)
        self.browser = browser
    }

    // MARK: - Dialing & handshake

    private func ensureConnections() {
        guard isRunning else { return }
        for (machineId, endpoint) in discoveredEndpoints {
            guard peers[machineId] == nil,
                  !pendingConnections.values.contains(where: { $0.remoteMachineId == machineId }),
                  Date() >= (nextDialAttempt[machineId] ?? .distantPast) else { continue }
            let connection = NWConnection(to: endpoint, using: Self.makeParameters())
            adopt(connection: connection, role: .outbound, machineId: machineId)
        }
    }

    private func adopt(connection: NWConnection, role: PeerConnection.Role, machineId: UUID?) {
        guard isRunning else {
            connection.cancel()
            return
        }
        let peer = PeerConnection(connection: connection, role: role, remoteMachineId: machineId)
        pendingConnections[ObjectIdentifier(peer)] = peer
        let helloFrame = FrameCodec.encodeJSON(.hello, HelloMessage(
            machineId: MachineIdentity.id,
            displayName: MachineIdentity.displayName,
            protocolVersion: Self.protocolVersion
        ))
        peer.onReady = { peer in
            // Symmetric handshake: both sides announce themselves on connect.
            if let helloFrame { peer.send(helloFrame) }
        }
        peer.onFrame = { [weak self] peer, type, payload in
            DispatchQueue.main.async {
                self?.handleFrame(peer, type: type, payload: payload)
            }
        }
        peer.onFailed = { [weak self] peer in
            DispatchQueue.main.async {
                self?.handleFailure(peer)
            }
        }
        peer.start(on: Self.networkQueue)
    }

    private func handleFailure(_ peer: PeerConnection) {
        pendingConnections.removeValue(forKey: ObjectIdentifier(peer))
        if let machineId = peer.remoteMachineId {
            // Exponential backoff while the Bonjour result lingers after death.
            let delay = min(Self.maxDialDelay, (dialDelay[machineId] ?? 0.5) * 2)
            dialDelay[machineId] = delay
            nextDialAttempt[machineId] = Date().addingTimeInterval(delay)
            if peers[machineId] === peer {
                peers.removeValue(forKey: machineId)
                peerWentOffline(machineId)
            }
        }
        peer.cancel()
    }

    private func peerWentOffline(_ machineId: UUID) {
        RemoteRuntime.sink?.setPeerOnline(machineId, false)
        RemoteRuntime.host?.unsubscribeAllMirrors(machineId: machineId)
        RemoteRuntime.terminalSink?.peerWentOffline(machineId)
    }

    private func registerPeer(_ peer: PeerConnection, hello: HelloMessage) {
        guard hello.protocolVersion == Self.protocolVersion else {
            print("[remote] rejecting \(hello.displayName): protocol \(hello.protocolVersion) != \(Self.protocolVersion)")
            pendingConnections.removeValue(forKey: ObjectIdentifier(peer))
            peer.cancel()
            return
        }
        // Trust anchor: only machines whose manifest reached us via the shared
        // iCloud account may connect.
        guard CloudSyncManager.shared.knownMachines[hello.machineId] != nil else {
            print("[remote] rejecting \(hello.displayName): \(hello.machineId) not in iCloud machine list")
            pendingConnections.removeValue(forKey: ObjectIdentifier(peer))
            peer.cancel()
            return
        }
        peer.remoteMachineId = hello.machineId
        peer.remoteName = hello.displayName
        pendingConnections.removeValue(forKey: ObjectIdentifier(peer))

        if let existing = peers[hello.machineId], existing !== peer {
            // Both sides dialed simultaneously — deterministically keep the
            // connection dialed by the lexicographically-lower machineId.
            let keepOutbound = MachineIdentity.id.uuidString < hello.machineId.uuidString
            let winner = (peer.role == .outbound) == keepOutbound ? peer : existing
            let loser = winner === peer ? existing : peer
            loser.onFailed = nil  // silent replacement, not an offline event
            loser.cancel()
            peers[hello.machineId] = winner
            if winner === existing { return }
        } else {
            peers[hello.machineId] = peer
        }

        dialDelay[hello.machineId] = nil
        nextDialAttempt[hello.machineId] = nil
        print("[remote] connected to \(hello.displayName) (\(hello.machineId))")
        RemoteRuntime.sink?.setPeerOnline(hello.machineId, true)
        RemoteRuntime.terminalSink?.peerCameOnline(hello.machineId)
        sendSessionList(to: peer)
    }

    // MARK: - Frame dispatch

    private func handleFrame(_ peer: PeerConnection, type: RemoteMessageType, payload: Data) {
        if type == .hello {
            guard let hello = FrameCodec.decodeJSON(HelloMessage.self, from: payload) else { return }
            registerPeer(peer, hello: hello)
            return
        }
        // Every other message requires a completed handshake.
        guard let machineId = peer.remoteMachineId, peers[machineId] === peer else { return }

        switch type {
        case .hello:
            break
        case .ping:
            peer.send(FrameCodec.frame(type: .pong, payload: Data()))
        case .pong:
            break  // lastReceivedAt already bumped
        case .sessionList:
            guard let message = FrameCodec.decodeJSON(SessionListMessage.self, from: payload) else { return }
            RemoteSessionCoordinator.shared.applyLiveSessionList(
                machineId: machineId,
                machineName: peer.remoteName ?? "Mac",
                snapshots: message.sessions
            )
        case .statusUpdate:
            guard let message = FrameCodec.decodeJSON(StatusUpdateMessage.self, from: payload) else { return }
            RemoteRuntime.sink?.applyRemoteStatus(
                message.sessionId,
                status: message.status,
                activityLine: message.activityLine,
                pendingPromptText: message.pendingPromptText,
                pendingChoices: message.pendingChoices,
                pendingQuestion: message.pendingQuestion,
                pendingPromptPreview: message.pendingPromptPreview,
                exchanges: message.exchanges,
                at: message.sentAt
            )
        case .subscribe:
            guard let message = FrameCodec.decodeJSON(SubscribeMessage.self, from: payload) else { return }
            handleSubscribe(peer, machineId: machineId, sessionId: message.sessionId)
        case .unsubscribe:
            guard let message = FrameCodec.decodeJSON(SubscribeMessage.self, from: payload) else { return }
            RemoteRuntime.host?.unsubscribeMirror(machineId: machineId, sessionId: message.sessionId)
        case .subscribeAck:
            guard let message = FrameCodec.decodeJSON(SubscribeAckMessage.self, from: payload) else { return }
            RemoteRuntime.terminalSink?.handleSubscribeAck(message, from: machineId)
        case .resize:
            guard let message = FrameCodec.decodeJSON(ResizeMessage.self, from: payload) else { return }
            RemoteRuntime.terminalSink?.handleResize(message, from: machineId)
        case .sessionClosed:
            guard let message = FrameCodec.decodeJSON(SessionClosedMessage.self, from: payload) else { return }
            // The tab itself lives on via sessionList/manifests — this only
            // means the PTY died (session restart or close on the worker).
            RemoteRuntime.terminalSink?.handleSessionClosed(message.sessionId, from: machineId)
        case .termSnapshot, .termData:
            guard let (sessionId, bytes) = FrameCodec.parseBinaryPayload(payload) else { return }
            RemoteRuntime.terminalSink?.handleTermData(
                sessionId: sessionId,
                bytes: bytes,
                isSnapshot: type == .termSnapshot,
                from: machineId
            )
        case .termInput:
            guard let (sessionId, bytes) = FrameCodec.parseBinaryPayload(payload) else { return }
            RemoteRuntime.host?.sendRawInput(to: sessionId, data: bytes)
        case .createSessionRequest:
            guard let request = FrameCodec.decodeJSON(RemoteCreateRequest.self, from: payload) else { return }
            let sessionId = RemoteSessionCoordinator.shared.handleCreateRequest(request, fileURL: nil)
            let response = CreateSessionResponseMessage(
                requestId: request.requestId,
                sessionId: sessionId,
                error: sessionId == nil ? "directory not found" : nil
            )
            if let frame = FrameCodec.encodeJSON(.createSessionResponse, response) {
                peer.send(frame)
            }
        case .createSessionResponse:
            guard let response = FrameCodec.decodeJSON(CreateSessionResponseMessage.self, from: payload) else { return }
            createResponseHandlers.removeValue(forKey: response.requestId)?(response)
        }
    }

    private func handleSubscribe(_ peer: PeerConnection, machineId: UUID, sessionId: UUID) {
        guard let subscription = RemoteRuntime.host?.subscribeMirror(machineId: machineId, sessionId: sessionId) else {
            let ack = SubscribeAckMessage(sessionId: sessionId, cols: 0, rows: 0, accepted: false)
            if let frame = FrameCodec.encodeJSON(.subscribeAck, ack) { peer.send(frame) }
            return
        }
        let ack = SubscribeAckMessage(
            sessionId: sessionId,
            cols: subscription.cols,
            rows: subscription.rows,
            accepted: true
        )
        if let frame = FrameCodec.encodeJSON(.subscribeAck, ack) { peer.send(frame) }
        peer.send(FrameCodec.encodeBinary(.termSnapshot, sessionId: sessionId, bytes: subscription.snapshot))
    }

    // MARK: - Maintenance

    private func maintain() {
        guard isRunning else { return }
        ensureConnections()
        let now = Date()
        if now.timeIntervalSince(lastPingAt) >= Self.pingInterval {
            lastPingAt = now
            let ping = FrameCodec.frame(type: .ping, payload: Data())
            for peer in peers.values { peer.send(ping) }
        }
        // Cull peers that stopped answering (sleep, cable pull) — TCP keepalive
        // alone can take minutes to notice.
        for (machineId, peer) in peers where now.timeIntervalSince(peer.lastReceivedAt) > Self.peerTimeout {
            print("[remote] peer \(peer.remoteName ?? machineId.uuidString) timed out")
            peers.removeValue(forKey: machineId)
            peer.cancel()
            peerWentOffline(machineId)
        }
    }

    // MARK: - Outbound API

    func isPeerOnline(_ machineId: UUID) -> Bool {
        peers[machineId] != nil
    }

    /// Called from SessionStore's live-scrape pipeline whenever a local
    /// session's displayed state changes. Coalesced ~100ms per burst.
    func sessionDidChange(_ id: UUID) {
        // Only a worker (a machine that owns local PTYs) broadcasts status.
        guard isRunning, !peers.isEmpty, RemoteRuntime.host != nil else { return }
        dirtySessionIds.insert(id)
        if statusDebounce != nil { return }
        statusDebounce = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            self?.statusDebounce = nil
            self?.flushStatusUpdates()
        }
    }

    private func flushStatusUpdates() {
        let ids = dirtySessionIds
        dirtySessionIds = []
        guard !peers.isEmpty, let host = RemoteRuntime.host else { return }
        for id in ids {
            // statusUpdateMessage returns nil for remote/vanished sessions.
            guard let message = host.statusUpdateMessage(for: id),
                  let frame = FrameCodec.encodeJSON(.statusUpdate, message) else { continue }
            for peer in peers.values { peer.send(frame) }
        }
    }

    /// Debounced full session-list broadcast — hooked from persistSessions so
    /// adds/removes/renames propagate without waiting on the iCloud cycle.
    func scheduleSessionListBroadcast() {
        guard isRunning, !peers.isEmpty, sessionListDebounce == nil else { return }
        sessionListDebounce = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.sessionListDebounce = nil
            for peer in self.peers.values { self.sendSessionList(to: peer) }
        }
    }

    private func sendSessionList(to peer: PeerConnection) {
        let message = SessionListMessage(sessions: RemoteRuntime.host?.currentSessionSnapshots() ?? [])
        if let frame = FrameCodec.encodeJSON(.sessionList, message) {
            peer.send(frame)
        }
    }

    func subscribe(machineId: UUID, sessionId: UUID) {
        guard let peer = peers[machineId],
              let frame = FrameCodec.encodeJSON(.subscribe, SubscribeMessage(sessionId: sessionId)) else { return }
        peer.send(frame)
    }

    func unsubscribe(machineId: UUID, sessionId: UUID) {
        guard let peer = peers[machineId],
              let frame = FrameCodec.encodeJSON(.unsubscribe, SubscribeMessage(sessionId: sessionId)) else { return }
        peer.send(frame)
    }

    func sendTermInput(machineId: UUID, sessionId: UUID, bytes: Data) {
        peers[machineId]?.send(FrameCodec.encodeBinary(.termInput, sessionId: sessionId, bytes: bytes))
    }

    /// Fan out live PTY output to a session's subscribers. Called by
    /// TerminalMirrorHub on every output burst.
    func sendTermData(to machineIds: Set<UUID>, sessionId: UUID, bytes: Data) {
        guard !machineIds.isEmpty else { return }
        let frame = FrameCodec.encodeBinary(.termData, sessionId: sessionId, bytes: bytes)
        for machineId in machineIds {
            peers[machineId]?.send(frame)
        }
    }

    func broadcastResize(sessionId: UUID, cols: Int, rows: Int, to machineIds: Set<UUID>) {
        guard !machineIds.isEmpty,
              let frame = FrameCodec.encodeJSON(.resize, ResizeMessage(sessionId: sessionId, cols: cols, rows: rows)) else { return }
        for machineId in machineIds {
            peers[machineId]?.send(frame)
        }
    }

    func broadcastSessionClosed(_ sessionId: UUID, to machineIds: Set<UUID>) {
        guard !machineIds.isEmpty,
              let frame = FrameCodec.encodeJSON(.sessionClosed, SessionClosedMessage(sessionId: sessionId)) else { return }
        for machineId in machineIds {
            peers[machineId]?.send(frame)
        }
    }

    /// Ask an online worker to create a session. Falls back to the iCloud
    /// queue at the call site when the peer is offline.
    func sendCreateSession(_ request: RemoteCreateRequest, completion: @escaping (CreateSessionResponseMessage?) -> Void) {
        guard let peer = peers[request.targetMachineId],
              let frame = FrameCodec.encodeJSON(.createSessionRequest, request) else {
            completion(nil)
            return
        }
        createResponseHandlers[request.requestId] = completion
        peer.send(frame)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            // Timed out — hand back nil so the caller can queue via iCloud.
            self?.createResponseHandlers.removeValue(forKey: request.requestId)?(nil)
        }
    }
}
