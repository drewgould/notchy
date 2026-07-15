import Foundation
import Network
import CryptoKit

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
    /// Held while any peer is connected so the process stays out of App Nap —
    /// otherwise the OS throttles `networkQueue` when the Mac locks and the
    /// inbound receive loop stalls (queued output still drains, so the viewer
    /// sees output but keystrokes never arrive). See `refreshServingActivity`.
    private var servingActivity: NSObjectProtocol?
    private var lastPingAt = Date.distantPast
    private var sessionListDebounce: Timer?
    /// Sessions with unsent live-state changes, flushed on a short debounce.
    private var dirtySessionIds: Set<UUID> = []
    private var statusDebounce: Timer?
    /// Completion handlers for in-flight network create requests. Called with
    /// nil on timeout so the caller can fall back to the iCloud queue.
    private var createResponseHandlers: [UUID: (CreateSessionResponseMessage?) -> Void] = [:]

    // MARK: Pairing state
    /// Untrusted, hello-completed connections held for discovery/pairing, keyed
    /// by machineId. Inert — only pair frames are processed for these.
    private var pairingCandidates: [UUID: PeerConnection] = [:]
    /// Our ephemeral private key for an in-flight pairing (initiator side).
    private var pairingEphemeral: [UUID: Curve25519.KeyAgreement.PrivateKey] = [:]
    /// Responder-side provisional key + transcript pubkeys awaiting pairConfirm.
    private var pendingResponderPairing: [UUID: (key: SymmetricKey, initiatorPub: Data, responderPub: Data)] = [:]
    /// Initiator-side: PIN the user entered for a machine we intend to pair with.
    private var pairingIntents: [UUID: String] = [:]

    /// UI callbacks, invoked on the main thread.
    var onCandidatesChanged: (() -> Void)?
    var onPairingSucceeded: ((UUID, String) -> Void)?
    var onPairingFailed: ((UUID) -> Void)?

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
        for peer in pairingCandidates.values { peer.cancel() }
        let machineIds = Array(peers.keys)
        peers = [:]
        pendingConnections = [:]
        pairingCandidates = [:]
        pairingEphemeral = [:]
        pendingResponderPairing = [:]
        pairingIntents = [:]
        discoveredEndpoints = [:]
        refreshServingActivity()
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
            if pairingCandidates[machineId] === peer {
                pairingCandidates.removeValue(forKey: machineId)
                pendingResponderPairing.removeValue(forKey: machineId)
                onCandidatesChanged?()
            }
        }
        peer.cancel()
    }

    private func peerWentOffline(_ machineId: UUID) {
        refreshServingActivity()
        RemoteRuntime.sink?.setPeerOnline(machineId, false)
        RemoteRuntime.host?.unsubscribeAllMirrors(machineId: machineId)
        RemoteRuntime.terminalSink?.peerWentOffline(machineId)
    }

    /// Trust anchor: a machine is trusted if its manifest reached us over the
    /// shared iCloud account (Mac-to-Mac) OR it has completed PIN pairing.
    private func isTrusted(_ machineId: UUID) -> Bool {
        CloudSyncManager.shared.knownMachines[machineId] != nil
            || PairingManager.shared.isPaired(machineId)
    }

    private func registerPeer(_ peer: PeerConnection, hello: HelloMessage) {
        guard hello.protocolVersion == Self.protocolVersion else {
            print("[remote] rejecting \(hello.displayName): protocol \(hello.protocolVersion) != \(Self.protocolVersion)")
            pendingConnections.removeValue(forKey: ObjectIdentifier(peer))
            peer.cancel()
            return
        }
        peer.remoteMachineId = hello.machineId
        peer.remoteName = hello.displayName
        pendingConnections.removeValue(forKey: ObjectIdentifier(peer))

        guard isTrusted(hello.machineId) else {
            // Untrusted — hold as a pairing candidate (inert; only pair frames
            // accepted) so the user can discover and pair with it.
            if let existing = pairingCandidates[hello.machineId], existing !== peer {
                existing.onFailed = nil
                existing.cancel()
            }
            pairingCandidates[hello.machineId] = peer
            onCandidatesChanged?()
            // If we're the initiator and the user already entered a PIN, start.
            if let pin = pairingIntents[hello.machineId] {
                beginInitiatorPairing(with: peer, machineId: hello.machineId, pin: pin)
            }
            return
        }

        completeTrustedRegistration(peer, machineId: hello.machineId, name: hello.displayName)
    }

    /// Promote a connection to a trusted peer: resolve simultaneous dials, wire
    /// it into `peers`, and kick off the session-list exchange.
    private func completeTrustedRegistration(_ peer: PeerConnection, machineId: UUID, name: String) {
        // Paired peers get an encrypted channel; iCloud-trusted Macs stay plaintext.
        // Set before any post-trust frame (e.g. the session list below) is sent.
        peer.encryptionKey = PairingManager.shared.key(for: machineId)
        pairingCandidates.removeValue(forKey: machineId)

        if let existing = peers[machineId], existing !== peer {
            // Both sides dialed simultaneously — deterministically keep the
            // connection dialed by the lexicographically-lower machineId.
            let keepOutbound = MachineIdentity.id.uuidString < machineId.uuidString
            let winner = (peer.role == .outbound) == keepOutbound ? peer : existing
            let loser = winner === peer ? existing : peer
            loser.onFailed = nil  // silent replacement, not an offline event
            loser.cancel()
            peers[machineId] = winner
            if winner === existing { return }
        } else {
            peers[machineId] = peer
        }

        dialDelay[machineId] = nil
        nextDialAttempt[machineId] = nil
        print("[remote] connected to \(name) (\(machineId))")
        refreshServingActivity()
        RemoteRuntime.sink?.setPeerOnline(machineId, true)
        RemoteRuntime.terminalSink?.peerCameOnline(machineId)
        sendSessionList(to: peer)
    }

    /// Take/drop an App Nap–preventing activity assertion based on whether any
    /// peer is currently connected. `userInitiatedAllowingIdleSystemSleep`
    /// keeps the process (and thus `networkQueue`'s receive loop) responsive
    /// while the Mac is locked without altering its idle-sleep policy.
    private func refreshServingActivity() {
        if !peers.isEmpty, servingActivity == nil {
            servingActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Serving remote terminal viewer"
            )
        } else if peers.isEmpty, let activity = servingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            servingActivity = nil
        }
    }

    // MARK: - Frame dispatch

    private func handleFrame(_ peer: PeerConnection, type: RemoteMessageType, payload: Data) {
        if type == .hello {
            guard let hello = FrameCodec.decodeJSON(HelloMessage.self, from: payload) else { return }
            registerPeer(peer, hello: hello)
            return
        }
        // Pairing frames ride an untrusted (candidate) connection.
        if type == .pairBegin || type == .pairResponse || type == .pairConfirm {
            handlePairingFrame(peer, type: type, payload: payload)
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
            // A viewer that was driving the size just left — restore natural dims.
            RemoteRuntime.host?.restoreNaturalSizeIfUnwatched(sessionId: message.sessionId)
        case .subscribeAck:
            guard let message = FrameCodec.decodeJSON(SubscribeAckMessage.self, from: payload) else { return }
            RemoteRuntime.terminalSink?.handleSubscribeAck(message, from: machineId)
        case .resize:
            guard let message = FrameCodec.decodeJSON(ResizeMessage.self, from: payload) else { return }
            RemoteRuntime.terminalSink?.handleResize(message, from: machineId)
        case .resizeRequest:
            // A viewer wants this worker's PTY sized to fit its screen.
            guard let message = FrameCodec.decodeJSON(ResizeMessage.self, from: payload) else { return }
            RemoteRuntime.host?.applyViewerResize(sessionId: message.sessionId, cols: message.cols, rows: message.rows)
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
        case .termImage:
            guard let (sessionId, bytes) = FrameCodec.parseBinaryPayload(payload) else { return }
            RemoteRuntime.host?.pasteImage(to: sessionId, data: bytes)
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
        case .pairBegin, .pairResponse, .pairConfirm:
            break  // handled above, before the trusted-peer guard
        }
    }

    // MARK: - Pairing

    /// Discovered, not-yet-paired peers — drives the "Add Mac" list.
    func discoveredUnpairedPeers() -> [(machineId: UUID, name: String)] {
        pairingCandidates.map { ($0.key, $0.value.remoteName ?? "Mac") }
    }

    /// Pairing UI entry point: intend to pair with `machineId` using `pin`.
    /// Starts immediately if the candidate connection already exists, otherwise
    /// begins as soon as it's discovered.
    func startPairing(machineId: UUID, pin: String) {
        pairingIntents[machineId] = pin
        if let peer = pairingCandidates[machineId] {
            beginInitiatorPairing(with: peer, machineId: machineId, pin: pin)
        }
    }

    func cancelPairing(machineId: UUID) {
        pairingIntents.removeValue(forKey: machineId)
        pairingEphemeral.removeValue(forKey: machineId)
    }

    /// Initiator: generate an ephemeral key and send pairBegin.
    private func beginInitiatorPairing(with peer: PeerConnection, machineId: UUID, pin: String) {
        let priv = PairingManager.newEphemeralKey()
        pairingEphemeral[machineId] = priv
        pairingIntents[machineId] = pin
        if let frame = FrameCodec.encodeJSON(.pairBegin,
                PairBeginMessage(initiatorPublicKey: priv.publicKey.rawRepresentation)) {
            peer.send(frame)
        }
    }

    private func handlePairingFrame(_ peer: PeerConnection, type: RemoteMessageType, payload: Data) {
        guard let machineId = peer.remoteMachineId, pairingCandidates[machineId] === peer else { return }
        switch type {
        case .pairBegin:   handlePairBegin(peer, machineId: machineId, payload: payload)
        case .pairResponse: handlePairResponse(peer, machineId: machineId, payload: payload)
        case .pairConfirm: handlePairConfirm(peer, machineId: machineId, payload: payload)
        default: break
        }
    }

    /// Responder: got the initiator's public key. Requires active pairing mode.
    private func handlePairBegin(_ peer: PeerConnection, machineId: UUID, payload: Data) {
        guard let pin = PairingManager.shared.activePIN,
              let msg = FrameCodec.decodeJSON(PairBeginMessage.self, from: payload) else { return }
        let priv = PairingManager.newEphemeralKey()
        let responderPub = priv.publicKey.rawRepresentation
        guard let key = PairingManager.sharedKey(myPrivate: priv, peerPublicKey: msg.initiatorPublicKey) else { return }
        let tag = PairingManager.confirmationTag(pin: pin, label: "R",
                                                 initiatorPublicKey: msg.initiatorPublicKey,
                                                 responderPublicKey: responderPub)
        pendingResponderPairing[machineId] = (key, msg.initiatorPublicKey, responderPub)
        if let frame = FrameCodec.encodeJSON(.pairResponse,
                PairResponseMessage(responderPublicKey: responderPub, confirmationTag: tag)) {
            peer.send(frame)
        }
    }

    /// Initiator: verify the responder proved PIN knowledge, persist the key,
    /// send our confirmation, and promote the connection to trusted.
    private func handlePairResponse(_ peer: PeerConnection, machineId: UUID, payload: Data) {
        guard let pin = pairingIntents[machineId],
              let priv = pairingEphemeral[machineId],
              let msg = FrameCodec.decodeJSON(PairResponseMessage.self, from: payload),
              let key = PairingManager.sharedKey(myPrivate: priv, peerPublicKey: msg.responderPublicKey) else {
            failInitiatorPairing(machineId)
            return
        }
        let initiatorPub = priv.publicKey.rawRepresentation
        let expected = PairingManager.confirmationTag(pin: pin, label: "R",
                                                      initiatorPublicKey: initiatorPub,
                                                      responderPublicKey: msg.responderPublicKey)
        guard PairingManager.tagsMatch(expected, msg.confirmationTag) else {
            failInitiatorPairing(machineId)  // wrong PIN or a MITM
            return
        }
        PairingManager.shared.storePairing(machineId: machineId, key: key)
        let ourTag = PairingManager.confirmationTag(pin: pin, label: "I",
                                                    initiatorPublicKey: initiatorPub,
                                                    responderPublicKey: msg.responderPublicKey)
        if let frame = FrameCodec.encodeJSON(.pairConfirm, PairConfirmMessage(confirmationTag: ourTag)) {
            peer.send(frame)
        }
        pairingEphemeral.removeValue(forKey: machineId)
        pairingIntents.removeValue(forKey: machineId)
        let name = peer.remoteName ?? "Mac"
        onPairingSucceeded?(machineId, name)
        completeTrustedRegistration(peer, machineId: machineId, name: name)
    }

    /// Responder: verify the initiator proved PIN knowledge, persist the key,
    /// leave pairing mode, and promote the connection to trusted.
    private func handlePairConfirm(_ peer: PeerConnection, machineId: UUID, payload: Data) {
        guard let pin = PairingManager.shared.activePIN,
              let pending = pendingResponderPairing[machineId],
              let msg = FrameCodec.decodeJSON(PairConfirmMessage.self, from: payload) else { return }
        let expected = PairingManager.confirmationTag(pin: pin, label: "I",
                                                      initiatorPublicKey: pending.initiatorPub,
                                                      responderPublicKey: pending.responderPub)
        guard PairingManager.tagsMatch(expected, msg.confirmationTag) else {
            pendingResponderPairing.removeValue(forKey: machineId)
            return
        }
        PairingManager.shared.storePairing(machineId: machineId, key: pending.key)
        pendingResponderPairing.removeValue(forKey: machineId)
        PairingManager.shared.endPairingMode()
        let name = peer.remoteName ?? "device"
        onPairingSucceeded?(machineId, name)
        completeTrustedRegistration(peer, machineId: machineId, name: name)
    }

    private func failInitiatorPairing(_ machineId: UUID) {
        pairingEphemeral.removeValue(forKey: machineId)
        pairingIntents.removeValue(forKey: machineId)
        onPairingFailed?(machineId)
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

    /// Ship a viewer-pasted PNG to the worker, which stages it on its clipboard
    /// and sends Claude a paste keystroke. Dropped (with a log) if it exceeds the
    /// frame cap — the viewer is expected to downscale first.
    func sendTermImage(machineId: UUID, sessionId: UUID, png: Data) {
        guard png.count + 16 <= FrameCodec.maxFrameLength else {
            print("[remote] not sending \(png.count)B image — exceeds frame cap")
            return
        }
        peers[machineId]?.send(FrameCodec.encodeBinary(.termImage, sessionId: sessionId, bytes: png))
    }

    /// Viewer → worker: ask the worker to size this session's PTY to `cols`×`rows`
    /// so the mirror fits this device's screen.
    func sendResizeRequest(machineId: UUID, sessionId: UUID, cols: Int, rows: Int) {
        guard let peer = peers[machineId],
              let frame = FrameCodec.encodeJSON(.resizeRequest, ResizeMessage(sessionId: sessionId, cols: cols, rows: rows)) else { return }
        peer.send(frame)
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
