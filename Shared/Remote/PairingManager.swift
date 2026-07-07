import Foundation
import CryptoKit
import Security

/// One-time-PIN device pairing shared by both platforms.
///
/// Trust today rides the iCloud manifest list (Macs signed into the same
/// account). An iPad can't publish to that shared folder, so it earns trust by
/// pairing: the Mac shows a 6-digit PIN, the iPad enters it, and the two run a
/// short PIN-authenticated ECDH. The PIN authenticates an ephemeral Curve25519
/// key agreement (via a PIN-keyed HMAC over both public keys), so:
///   * an unpaired device is rejected — it can't produce a valid confirmation;
///   * a passive eavesdropper can't recover the long-term key by brute-forcing
///     the 6-digit PIN offline, because the key comes from the ECDH secret, not
///     from the PIN.
/// The resulting 32-byte key is stored per peer in the Keychain and gates trust
/// on every future connection. (Encrypting the channel with it via TLS-PSK is a
/// follow-on; this layer is access control.)
final class PairingManager {
    static let shared = PairingManager()

    private static let keychainService = "com.notchy.pairing"

    /// In-memory cache of paired peers → 32-byte key. Backed by the Keychain.
    private var keys: [UUID: SymmetricKey]

    private init() {
        keys = PairingManager.loadAllFromKeychain()
    }

    // MARK: - Paired-peer store

    func isPaired(_ machineId: UUID) -> Bool { keys[machineId] != nil }

    func key(for machineId: UUID) -> SymmetricKey? { keys[machineId] }

    var pairedMachineIds: [UUID] { Array(keys.keys) }

    func storePairing(machineId: UUID, key: SymmetricKey) {
        keys[machineId] = key
        PairingManager.saveToKeychain(machineId: machineId, key: key)
    }

    func removePairing(_ machineId: UUID) {
        keys.removeValue(forKey: machineId)
        PairingManager.deleteFromKeychain(machineId: machineId)
    }

    func removeAll() {
        for id in keys.keys { PairingManager.deleteFromKeychain(machineId: id) }
        keys.removeAll()
    }

    // MARK: - Pairing mode (responder / the Mac showing the PIN)

    /// The PIN currently displayed while accepting a pairing, or nil.
    private(set) var activePIN: String?
    var isPairingModeActive: Bool { activePIN != nil }

    /// Begin accepting a pairing and return the 6-digit PIN to display.
    @discardableResult
    func beginPairingMode(pin: String) -> String {
        activePIN = pin
        return pin
    }

    func endPairingMode() { activePIN = nil }

    // MARK: - Crypto helpers (pure)

    static func newEphemeralKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    /// Derive the shared 32-byte key from our private key and the peer's public
    /// key bytes. Returns nil if the peer key is malformed.
    static func sharedKey(myPrivate: Curve25519.KeyAgreement.PrivateKey,
                          peerPublicKey: Data) -> SymmetricKey? {
        guard let peerPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey),
              let secret = try? myPrivate.sharedSecretFromKeyAgreement(with: peerPub) else { return nil }
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("notchy-pairing-salt".utf8),
            sharedInfo: Data("notchy-pairing-key".utf8),
            outputByteCount: 32
        )
    }

    /// PIN-authenticated confirmation tag over the pairing transcript. `label`
    /// distinguishes initiator ("I") from responder ("R") so the two tags differ.
    static func confirmationTag(pin: String,
                                label: String,
                                initiatorPublicKey: Data,
                                responderPublicKey: Data) -> Data {
        let pinKey = SymmetricKey(data: SHA256.hash(data: Data(pin.utf8)))
        var message = Data(label.utf8)
        message.append(initiatorPublicKey)
        message.append(responderPublicKey)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: pinKey)
        return Data(mac)
    }

    /// Constant-time compare for confirmation tags.
    static func tagsMatch(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    /// A random 6-digit PIN as a zero-padded string.
    static func randomPIN() -> String {
        let n = UInt32.random(in: 0..<1_000_000)
        return String(format: "%06u", n)
    }

    // MARK: - Keychain

    private static func account(_ machineId: UUID) -> String { machineId.uuidString }

    private static func saveToKeychain(machineId: UUID, key: SymmetricKey) {
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account(machineId),
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func deleteFromKeychain(machineId: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account(machineId),
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func loadAllFromKeychain() -> [UUID: SymmetricKey] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [:] }
        var out: [UUID: SymmetricKey] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let machineId = UUID(uuidString: account),
                  let data = item[kSecValueData as String] as? Data else { continue }
            out[machineId] = SymmetricKey(data: data)
        }
        return out
    }
}
