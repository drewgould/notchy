import Foundation

/// Wire protocol between Notchy instances: length-prefixed frames over TCP.
///
///   frame  := length  UInt32 big-endian (bytes after this field, ≤ 1 MB)
///             type    UInt8 (RemoteMessageType raw value)
///             payload
///
/// Control messages carry UTF-8 JSON of the matching Codable struct. Terminal
/// data (types ≥ 0x10) is binary: 16 raw UUID bytes then raw PTY bytes —
/// never base64.
nonisolated enum RemoteMessageType: UInt8 {
    case hello = 0x01
    case ping = 0x03
    case pong = 0x04
    /// Worker → viewer: full snapshot of the worker's local sessions.
    /// Sent right after `hello` and re-sent (debounced) on session churn.
    case sessionList = 0x05
    /// Worker → viewer: one session's live scraped state.
    case statusUpdate = 0x06
    case subscribe = 0x07
    case unsubscribe = 0x08
    /// Worker → viewer: subscription accepted; carries PTY dims. A
    /// `termSnapshot` follows immediately.
    case subscribeAck = 0x09
    /// Worker → viewer: PTY dims changed.
    case resize = 0x0A
    case createSessionRequest = 0x0B
    case createSessionResponse = 0x0C
    case sessionClosed = 0x0D
    /// Binary. Full-reset + ring-buffer backfill on subscribe.
    case termSnapshot = 0x10
    /// Binary. Live PTY output.
    case termData = 0x11
    /// Binary. Viewer keystrokes destined for the worker's PTY.
    case termInput = 0x12

    // Pairing block (JSON). Exchanged on an untrusted connection to establish a
    // per-peer key via a PIN-authenticated ECDH.
    /// Initiator → responder: initiator's ephemeral public key.
    case pairBegin = 0x20
    /// Responder → initiator: responder's ephemeral public key + PIN-keyed tag.
    case pairResponse = 0x21
    /// Initiator → responder: initiator's PIN-keyed confirmation tag.
    case pairConfirm = 0x22
}

// MARK: - Control message payloads

nonisolated struct HelloMessage: Codable {
    let machineId: UUID
    let displayName: String
    let protocolVersion: Int
}

nonisolated struct SessionListMessage: Codable {
    let sessions: [SessionSnapshot]
}

nonisolated struct StatusUpdateMessage: Codable {
    let sessionId: UUID
    let status: TerminalStatus
    let activityLine: String?
    let pendingPromptText: String?
    let pendingChoices: [PromptChoice]
    let pendingQuestion: String?
    let pendingPromptPreview: String?
    let exchanges: [TaskExchange]
    let sentAt: Date
}

nonisolated struct SubscribeMessage: Codable {
    let sessionId: UUID
}

nonisolated struct SubscribeAckMessage: Codable {
    let sessionId: UUID
    let cols: Int
    let rows: Int
    let accepted: Bool
}

nonisolated struct ResizeMessage: Codable {
    let sessionId: UUID
    let cols: Int
    let rows: Int
}

nonisolated struct CreateSessionResponseMessage: Codable {
    let requestId: UUID
    let sessionId: UUID?
    let error: String?
}

nonisolated struct SessionClosedMessage: Codable {
    let sessionId: UUID
}

// MARK: - Pairing payloads

nonisolated struct PairBeginMessage: Codable {
    let initiatorPublicKey: Data
}

nonisolated struct PairResponseMessage: Codable {
    let responderPublicKey: Data
    let confirmationTag: Data
}

nonisolated struct PairConfirmMessage: Codable {
    let confirmationTag: Data
}

// MARK: - Framing

nonisolated enum FrameCodec {
    /// Well above any control message or PTY burst; a frame claiming more is
    /// a corrupt stream and the connection gets dropped.
    static let maxFrameLength = 1_048_576

    static func encodeJSON<T: Encodable>(_ type: RemoteMessageType, _ message: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let payload = try? encoder.encode(message) else { return nil }
        return frame(type: type, payload: payload)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from payload: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: payload)
    }

    static func encodeBinary(_ type: RemoteMessageType, sessionId: UUID, bytes: Data) -> Data {
        var payload = withUnsafeBytes(of: sessionId.uuid) { Data($0) }
        payload.append(bytes)
        return frame(type: type, payload: payload)
    }

    static func parseBinaryPayload(_ payload: Data) -> (sessionId: UUID, bytes: Data)? {
        guard payload.count >= 16 else { return nil }
        let uuid = payload.prefix(16).withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        return (UUID(uuid: uuid), payload.dropFirst(16))
    }

    static func frame(type: RemoteMessageType, payload: Data) -> Data {
        var data = Data(capacity: payload.count + 5)
        withUnsafeBytes(of: UInt32(payload.count + 1).bigEndian) { data.append(contentsOf: $0) }
        data.append(type.rawValue)
        data.append(payload)
        return data
    }
}

/// Streaming frame parser: feed raw TCP bytes, pop complete frames.
nonisolated struct FrameDecoder {
    enum FrameError: Error {
        case oversizedFrame
        case unknownType(UInt8)
    }

    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns nil when no complete frame is buffered yet. Throws on a corrupt
    /// stream — the caller should drop the connection.
    mutating func next() throws -> (type: RemoteMessageType, payload: Data)? {
        guard buffer.count >= 5 else { return nil }
        let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length >= 1, length <= UInt32(FrameCodec.maxFrameLength) else {
            throw FrameError.oversizedFrame
        }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let typeByte = buffer[buffer.startIndex + 4]
        let payload = buffer.subdata(in: (buffer.startIndex + 5)..<(buffer.startIndex + total))
        buffer.removeFirst(total)
        guard let type = RemoteMessageType(rawValue: typeByte) else {
            throw FrameError.unknownType(typeByte)
        }
        return (type, payload)
    }
}
