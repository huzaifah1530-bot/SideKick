import Foundation

struct StorageInstalledVersion: Sendable {
    let identifiers: Set<String>
    let name: String
    let version: String
    let build: String
}

enum StorageArchiveImportance {
    static func owner(bundleID: String, version: String, build: String?, installed: [StorageInstalledVersion]) -> String? {
        installed.first {
            $0.identifiers.contains(bundleID) && $0.version == version
                && (build == nil || build == $0.build)
        }?.name
    }
}
