import Foundation
#if os(iOS)
import UIKit
#endif

/// Stable identity for this Mac across launches. Every remote-tabs component —
/// iCloud manifests, Bonjour TXT records, create-request targeting — keys off
/// this UUID, so it must never change once minted.
enum MachineIdentity {
    private static let defaultsKey = "machineIdentityId"

    /// Per-install UUID, minted on first access. `NOTCHY_MACHINE_ID_OVERRIDE`
    /// lets a second instance on the same Mac pretend to be a different
    /// machine for loopback testing.
    static let id: UUID = {
        if let override = ProcessInfo.processInfo.environment["NOTCHY_MACHINE_ID_OVERRIDE"],
           let uuid = UUID(uuidString: override) {
            return uuid
        }
        if let stored = UserDefaults.standard.string(forKey: defaultsKey),
           let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let uuid = UUID()
        UserDefaults.standard.set(uuid.uuidString, forKey: defaultsKey)
        return uuid
    }()

    /// Human-readable name shown on other devices ("Andrew's MacBook Pro",
    /// "Andrew's iPad").
    static var displayName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? Host.current().name ?? "Mac"
        #endif
    }

    static var hostname: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().name ?? ""
        #endif
    }
}
