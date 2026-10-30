import Foundation

/// A device-accepted native installation supersedes stale recovery markers.
/// This updates tracking only; retained binaries, transfer exports and backups stay intact.
enum AppInstallationState {
    static func recordSuccessfulInstall(identifier: String, defaults: UserDefaults = .standard) {
        for prefix in ["SideKick.offload.", "SideKick.binary-recovery.", "SideKick.hidden-offloaded."] {
            defaults.removeObject(forKey: prefix + identifier)
        }
        let key = "SideKick.transfer." + identifier
        if let data = defaults.data(forKey: key),
           var record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            record["state"] = "active"
            if let updated = try? JSONSerialization.data(withJSONObject: record) { defaults.set(updated, forKey: key) }
        }
    }
}
