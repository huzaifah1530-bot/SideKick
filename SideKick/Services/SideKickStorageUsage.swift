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
            let documentsURL = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let libraryURL = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            let supportURL = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let temporaryURL = manager.temporaryDirectory
            let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
            let documents = documentsURL.standardizedFileURL
            let library = libraryURL.standardizedFileURL
            let support = supportURL.standardizedFileURL
            let temporary = temporaryURL.standardizedFileURL
            let cache = cache.standardizedFileURL
            let exports = documents.appendingPathComponent("ResignedApps", isDirectory: true)
            let imports = support.appendingPathComponent("ImportedIPAs", isDirectory: true)
            var result = SideKickStorageUsage()
            var documentBytes: Int64 = 0
            var libraryBytes: Int64 = 0
            var temporaryBytes: Int64 = 0
            var containerBytes: Int64 = 0

            func isWithin(_ path: URL, _ root: URL) -> Bool {
                let path = path.standardizedFileURL.path
                let root = root.standardizedFileURL.path
                return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }

            func add(_ bytes: Int64, at file: URL, relativeTo root: URL) {
                guard isWithin(file, root) else { return }
                if root == container { containerBytes += bytes }
                if root == documents { documentBytes += bytes }
                if root == library { libraryBytes += bytes }
                if root == temporary { temporaryBytes += bytes }
                if root == cache { result.signingCache += bytes }
                if root == exports { result.exportedIPAs += bytes }
                if root == imports { result.importedIPAs += bytes }
            }

            func accumulate(_ root: URL) {
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey,
                    .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
                guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: []) else { return }
                for case let file as URL in enumerator {
                    guard let values = try? file.resourceValues(forKeys: keys), values.isSymbolicLink != true else {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard values.isRegularFile == true else { continue }
                    let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
                    add(bytes, at: file, relativeTo: container)
                    add(bytes, at: file, relativeTo: documents)
                    add(bytes, at: file, relativeTo: library)
                    add(bytes, at: file, relativeTo: temporary)
                    add(bytes, at: file, relativeTo: cache)
                    add(bytes, at: file, relativeTo: exports)
                    add(bytes, at: file, relativeTo: imports)
                }
            }

            accumulate(container)
            result.temporaryFiles = temporaryBytes
            result.totalContainer = containerBytes
            result.directories = [
                StorageDirectoryUsage(name: "Documents", url: documents, bytes: documentBytes),
                StorageDirectoryUsage(name: "Library", url: library, bytes: libraryBytes),
                StorageDirectoryUsage(name: "Temporary Files", url: temporary, bytes: temporaryBytes)
            ]
            // Legacy App Group copies live outside the private app container.
            if let group = Bundle.main.altstoreAppGroup,
               let shared = manager.containerURL(forSecurityApplicationGroupIdentifier: group),
               !isWithin(shared, container) {
                var sharedBytes: Int64 = 0
                let shared = shared.standardizedFileURL
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey,
                    .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
                if let enumerator = manager.enumerator(at: shared, includingPropertiesForKeys: Array(keys), options: []) {
                    for case let file as URL in enumerator {
                        guard let values = try? file.resourceValues(forKeys: keys), values.isSymbolicLink != true else {
                            enumerator.skipDescendants()
                            continue
                        }
                        guard values.isRegularFile == true else { continue }
                        let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
                        sharedBytes += bytes
                        if isWithin(file, cache) { result.signingCache += bytes }
                    }
                }
                if sharedBytes > 0 {
                    result.directories.append(StorageDirectoryUsage(name: "Shared App Group", url: shared, bytes: sharedBytes))
                    result.totalContainer += sharedBytes
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
