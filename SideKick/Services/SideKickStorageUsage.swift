import Foundation

struct StorageDirectoryUsage: Identifiable, Sendable {
    let name: String
    let url: URL
    let bytes: Int64
    var id: String { url.path }
}

struct SideKickStorageUsage: Sendable {
    var signingCache: Int64 = 0
    var temporaryFiles: Int64 = 0
    var exportedIPAs: Int64 = 0
    var importedIPAs: Int64 = 0
    var totalContainer: Int64 = 0
    var directories: [StorageDirectoryUsage] = []

    func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func measure() async -> SideKickStorageUsage {
        let cache = InstalledApp.appsDirectoryURL
        return await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let library = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let temporary = manager.temporaryDirectory
            let directories = [
                StorageDirectoryUsage(name: "Documents", url: documents, bytes: size(of: documents)),
                StorageDirectoryUsage(name: "Library", url: library, bytes: size(of: library)),
                StorageDirectoryUsage(name: "Temporary Files", url: temporary, bytes: size(of: temporary))
            ]
            var result = SideKickStorageUsage(signingCache: size(of: cache),
                temporaryFiles: size(of: temporary),
                exportedIPAs: size(of: documents.appendingPathComponent("ResignedApps")),
                importedIPAs: size(of: support.appendingPathComponent("ImportedIPAs")),
                totalContainer: size(of: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)),
                directories: directories)
            // Legacy App Group copies live outside the private app container.
            if let group = Bundle.main.altstoreAppGroup,
               let shared = manager.containerURL(forSecurityApplicationGroupIdentifier: group),
               !shared.standardizedFileURL.path.hasPrefix(NSHomeDirectory() + "/") {
                let bytes = size(of: shared)
                if bytes > 0 {
                    result.directories.append(StorageDirectoryUsage(name: "Shared App Group", url: shared, bytes: bytes))
                    result.totalContainer += bytes
                }
            }
            return result
        }.value
    }

    static func children(of directory: URL) async -> [StorageDirectoryUsage] {
        await Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
            return files.filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
                .map { StorageDirectoryUsage(name: $0.lastPathComponent, url: $0, bytes: size(of: $0)) }
                .sorted { $0.bytes > $1.bytes }
        }.value
    }

    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        func bytes(_ file: URL) -> Int64 {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true, values.isRegularFile == true else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return 0 }
        if values.isRegularFile == true { return bytes(url) }
        guard let files = FileManager.default.enumerator(at: url,
            includingPropertiesForKeys: Array(keys), options: []) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                files.skipDescendants()
            } else { total += bytes(file) }
        }
        return total
    }
}
