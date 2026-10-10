import Foundation

struct SideKickStorageUsage: Sendable {
    var signingCache: Int64 = 0
    var temporaryFiles: Int64 = 0
    var exportedIPAs: Int64 = 0

    func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func measure() async -> SideKickStorageUsage {
        let cache = InstalledApp.appsDirectoryURL
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory
        let exports = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ResignedApps", isDirectory: true)
        return await Task.detached(priority: .utility) {
            let candidates = (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
            let ownedTemporary = candidates.filter {
                $0.lastPathComponent.hasPrefix("sidekick-pipeline-")
                    || $0.lastPathComponent.hasPrefix("sidekick-import-")
                    || $0.lastPathComponent.hasPrefix("sidekick-github-")
            }
            return SideKickStorageUsage(
                signingCache: size(of: cache),
                temporaryFiles: ownedTemporary.reduce(0) { $0 + size(of: $1) },
                exportedIPAs: size(of: exports)
            )
        }.value
    }

    private static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        guard let files = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return 0 }
        var bytes: Int64 = 0
        for case let file as URL in files {
            if let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true {
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        return bytes
    }
}
