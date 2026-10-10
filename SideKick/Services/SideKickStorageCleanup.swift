import Foundation

enum OwnedStoragePath {
    static func validate(_ candidate: URL, inside root: URL) throws {
        let root = root.standardizedFileURL
        let candidate = candidate.standardizedFileURL
        guard root.isFileURL, candidate.isFileURL,
              candidate.path.hasPrefix(root.path + "/"),
              candidate.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw StorageCleanupError.unsafePath
        }
        var cursor = candidate
        while cursor.path != root.path {
            let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw StorageCleanupError.unsafePath }
            cursor.deleteLastPathComponent()
        }
        guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw StorageCleanupError.unsafePath }
    }
}

struct StorageRemovalPolicy: Sendable {
    let owner: String?
    let requiresSourceConfirmation: Bool
    var ownerIdentifiers: Set<String> = []
    func canRemove(consent: StorageRemovalPolicy, allowRetainedSource: Bool) -> Bool {
        ownerIdentifiers == consent.ownerIdentifiers && owner == consent.owner && requiresSourceConfirmation == consent.requiresSourceConfirmation
            && (!requiresSourceConfirmation || allowRetainedSource)
    }
    static func payload(signature: String, retainedSignatures: [String: String], retainedIdentities: [String: Set<String>] = [:]) -> StorageRemovalPolicy {
        let owner = retainedSignatures[signature]
        return StorageRemovalPolicy(owner: owner, requiresSourceConfirmation: owner != nil, ownerIdentifiers: retainedIdentities[signature] ?? [])
    }
}

enum StorageCleanupError: LocalizedError {
    case unsafePath, operationRunning, protectedFile
    var errorDescription: String? {
        switch self {
        case .unsafePath: "This path is outside SideKick’s removable storage or contains a symbolic link."
        case .operationRunning: "Wait for app signing, refresh, imports, and downloads to finish before removing files."
        case .protectedFile: "This item contains app records or settings and cannot be removed here."
        }
    }
}

#if canImport(UIKit)
import CoreData

struct RemovableStorageItem: Identifiable, Sendable {
    let url: URL
    let name: String
    let bytes: Int64
    let policy: StorageRemovalPolicy
    let protectedReason: String?
    var id: String { url.path }
}

@MainActor
enum SideKickStorageCleanup {
    private(set) static var isRemovingFiles = false

    static func ensureOperationAllowed() throws {
        if isRemovingFiles { throw StorageCleanupError.operationRunning }
    }

    static func items() async throws -> [RemovableStorageItem] {
        let owners = try await payloadOwners()
        let payloads = InstalledApp.appsDirectoryURL.appendingPathComponent("Payloads", isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory
        let exports = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ResignedApps")
        return await Task.detached(priority: .utility) {
            var result: [RemovableStorageItem] = []
            for (root, category) in [(payloads, "Signing source"), (temporary, "Temporary"), (exports, "Export")] {
                guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                for url in children {
                    let safe = (try? OwnedStoragePath.validate(url, inside: root)) != nil
                    let policy = category == "Signing source" ? StorageRemovalPolicy.payload(signature: url.lastPathComponent, retainedSignatures: owners.names, retainedIdentities: owners.identities) : StorageRemovalPolicy(owner: nil, requiresSourceConfirmation: false)
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
                    let currentProcess = "\(ProcessInfo.processInfo.processIdentifier)"
                    let namedByCurrentProcess = url.lastPathComponent.hasPrefix("sidekick-import-\(currentProcess)-") || url.lastPathComponent.hasPrefix("sidekick-github-\(currentProcess)-")
                    let owner = try? String(contentsOf: url.appendingPathComponent(".sidekick-process"), encoding: .utf8)
                    let protected: String?
                    if !safe { protected = "Contains a symbolic link or an unsafe path." }
                    else if category == "Temporary" && (namedByCurrentProcess || owner == currentProcess || modified > Date.now.addingTimeInterval(-24 * 60 * 60)) {
                        protected = "Recent temporary file or owned by this running process. Kept to protect active work."
                    } else if category == "Export" && url.pathExtension.lowercased() != "ipa" { protected = "Not an exported IPA." }
                    else { protected = nil }
                    result.append(RemovableStorageItem(url: url, name: policy.owner.map { "\(category) · \($0)" } ?? "\(category) · \(url.lastPathComponent)",
                        bytes: SideKickStorageUsage.size(of: url), policy: policy, protectedReason: protected))
                }
            }
            return result.sorted { $0.bytes > $1.bytes }
        }.value
    }

    static func remove(_ item: RemovableStorageItem, downloads: GitHubUpdateDownloadStore, allowRetainedSource: Bool) async throws {
        guard !isRemovingFiles, !AppManager.shared.isActivelyManagingAnyApp, !downloads.jobs.values.contains(where: \.isDownloading) else {
            throw StorageCleanupError.operationRunning
        }
        isRemovingFiles = true
        defer { isRemovingFiles = false }
        // Re-read policy immediately before deleting; catalogue changes can make
        // a formerly unused payload the current source for an installed app.
        let current = try await items()
        guard let latest = current.first(where: { $0.id == item.id }), latest.protectedReason == nil,
              latest.policy.canRemove(consent: item.policy, allowRetainedSource: allowRetainedSource) else { throw StorageCleanupError.protectedFile }
        guard !AppManager.shared.isActivelyManagingAnyApp, !downloads.jobs.values.contains(where: \.isDownloading) else { throw StorageCleanupError.operationRunning }
        let payloads = InstalledApp.appsDirectoryURL.appendingPathComponent("Payloads")
        let temporary = FileManager.default.temporaryDirectory
        let exports = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ResignedApps")
        guard let root = [payloads, temporary, exports].first(where: { latest.url.deletingLastPathComponent().standardizedFileURL == $0.standardizedFileURL }) else {
            throw StorageCleanupError.unsafePath
        }
        try await Task.detached(priority: .utility) {
            try OwnedStoragePath.validate(latest.url, inside: root)
            try FileManager.default.removeItem(at: latest.url)
        }.value
    }

    static func cleanUnused(downloads: GitHubUpdateDownloadStore) async throws -> String {
        guard !isRemovingFiles, !AppManager.shared.isActivelyManagingAnyApp, !downloads.jobs.values.contains(where: \.isDownloading) else { throw StorageCleanupError.operationRunning }
        let candidates = try await items()
        var removed: Int64 = 0
        var count = 0
        var failures: [String] = []
        for item in candidates where item.protectedReason == nil && !item.policy.requiresSourceConfirmation && !item.name.hasPrefix("Export") {
            do { try await remove(item, downloads: downloads, allowRetainedSource: false); removed += item.bytes; count += 1 }
            catch { failures.append("\(item.name): \(error.localizedDescription)") }
        }
        let kept = candidates.filter { $0.policy.requiresSourceConfirmation || $0.protectedReason != nil }.count
        return "Removed \(count) items (\(ByteCountFormatter.string(fromByteCount: removed, countStyle: .file))). Kept \(kept) protected or required sources. Exports are kept."
            + (failures.isEmpty ? "" : "\n\n" + failures.joined(separator: "\n"))
    }

    private static func payloadOwners() async throws -> (names: [String: String], identities: [String: Set<String>]) {
        guard DatabaseManager.shared.isStarted else { throw StorageCleanupError.protectedFile }
        let context = DatabaseManager.shared.viewContext
        return try await context.perform {
            var owners: [String: Set<String>] = [:]
            var identities: [String: Set<String>] = [:]
            for app in try context.fetch(InstalledApp.fetchRequest()) where !app.isDeleted {
                if let signature = app.appBundleFingerprint {
                    owners[signature, default: []].insert(app.name)
                    identities[signature, default: []].insert(app.resignedBundleIdentifier)
                }
            }
            return (owners.mapValues { $0.sorted().joined(separator: ", ") }, identities)
        }
    }
}
#endif
