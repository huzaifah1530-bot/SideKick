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
    private static var activeOperations = 0
    private static var initialTemporaryPaths: Set<String>?
    private static var completedTemporaryPaths: Set<String> = []

    // Snapshot before preparation; only newly created staging folders belong
    // to this signing batch. Older and recovery folders remain protected.
    static func beginOperation() throws {
        try ensureOperationAllowed()
        if activeOperations == 0 {
            initialTemporaryPaths = (try? FileManager.default.contentsOfDirectory(
                at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)).map { Set($0.map(\.path)) }
        }
        activeOperations += 1
    }

    static func endOperation() {
        activeOperations -= 1
        guard activeOperations == 0 else { return }
        let root = FileManager.default.temporaryDirectory
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if let initialTemporaryPaths, !initialTemporaryPaths.contains(url.path), isStagedPipelineDirectory(url) {
                completedTemporaryPaths.insert(url.path)
                // Persist ownership for a later launch if this cleanup is
                // interrupted. Unmarked legacy folders are never inferred
                // disposable merely because they contain an IPA.
                try? Data("SideKick completed staging v1\n".utf8).write(
                    to: url.appendingPathComponent(".sidekick-disposable"), options: .atomic)
            }
        }
        initialTemporaryPaths = nil
        Task { await SideStoreOperationService.pruneUnusedCaches() }
    }

    static var hasActiveOperations: Bool { activeOperations > 0 }

    static func finishTemporaryFile(_ url: URL) {
        let root = FileManager.default.temporaryDirectory
        guard (try? OwnedStoragePath.validate(url, inside: root)) != nil,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return }
        if isOwnedTemporaryFile(url) { completedTemporaryPaths.insert(url.path) }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func isStagedPipelineDirectory(_ url: URL) -> Bool {
        guard (try? OwnedStoragePath.validate(url, inside: FileManager.default.temporaryDirectory)) != nil,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
              !children.isEmpty,
              children.allSatisfy({ ["App.app", "App.ipa", ".sidekick-disposable"].contains($0.lastPathComponent) }),
              children.allSatisfy({ (try? OwnedStoragePath.validate($0, inside: url)) != nil }) else { return false }
        // Recovery/backup folders and unexpected files make this ineligible.
        return children.contains { child in
            (child.lastPathComponent == "App.app"
                && FileManager.default.fileExists(atPath: child.appendingPathComponent("Info.plist").path))
                || (child.lastPathComponent == "App.ipa"
                    && (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true)
        }
    }

    nonisolated private static func isCompletedPipelineDirectory(_ url: URL) -> Bool {
        guard isStagedPipelineDirectory(url) else { return false }
        return (try? String(contentsOf: url.appendingPathComponent(".sidekick-disposable"), encoding: .utf8)) == "SideKick completed staging v1\n"
    }

    nonisolated static func isOwnedTemporaryFile(_ url: URL) -> Bool {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count == 8, parts[0] == "sidekick", ["import", "github"].contains(String(parts[1])),
              Int(parts[2]) != nil, url.pathExtension.lowercased() == "ipa",
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
        return UUID(uuidString: parts.dropFirst(3).joined(separator: "-")) != nil
    }

    static func ensureOperationAllowed() throws {
        if isRemovingFiles { throw StorageCleanupError.operationRunning }
    }

    static func items(includeExports: Bool = true, measureSizes: Bool = true) async throws -> [RemovableStorageItem] {
        let owners = try await payloadOwners()
        let payloads = InstalledApp.appsDirectoryURL.appendingPathComponent("Payloads", isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory
        let exports = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ResignedApps")
        let completedPaths = completedTemporaryPaths
        return await Task.detached(priority: .utility) {
            var result: [RemovableStorageItem] = []
            let roots = [(payloads, "Signing source"), (temporary, "Temporary")] + (includeExports ? [(exports, "Export")] : [])
            for (root, category) in roots {
                guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                for url in children {
                    let safe = (try? OwnedStoragePath.validate(url, inside: root)) != nil
                    let policy = category == "Signing source" ? StorageRemovalPolicy.payload(signature: url.lastPathComponent, retainedSignatures: owners.names, retainedIdentities: owners.identities) : StorageRemovalPolicy(owner: nil, requiresSourceConfirmation: false)
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
                    let currentProcess = "\(ProcessInfo.processInfo.processIdentifier)"
                    let namedByCurrentProcess = url.lastPathComponent.hasPrefix("sidekick-import-\(currentProcess)-") || url.lastPathComponent.hasPrefix("sidekick-github-\(currentProcess)-")
                    let owner = try? String(contentsOf: url.appendingPathComponent(".sidekick-process"), encoding: .utf8)
                    let finishedPipeline = category == "Temporary" && isStagedPipelineDirectory(url)
                        && (completedPaths.contains(url.path) || isCompletedPipelineDirectory(url))
                    let protected: String?
                    if !safe { protected = "Contains a symbolic link or an unsafe path." }
                    else if category == "Signing source" && (url.lastPathComponent.count != 64 || !url.lastPathComponent.allSatisfy({ $0.isHexDigit })) {
                        protected = "Not a disposable SideKick signing cache."
                    }
                    else if category == "Signing source" && !policy.requiresSourceConfirmation && modified > Date.now.addingTimeInterval(-24 * 60 * 60) {
                        protected = "Recent source kept for recovery after signing. It can be cleaned after 24 hours."
                    }
                    else if category == "Temporary" && !isOwnedTemporaryFile(url) && !finishedPipeline {
                        protected = "Not a disposable SideKick install file."
                    }
                    else if category == "Temporary" && !finishedPipeline && !completedPaths.contains(url.path) && (namedByCurrentProcess || owner == currentProcess || modified > Date.now.addingTimeInterval(-24 * 60 * 60)) {
                        protected = "Recent temporary file or owned by this running process. Kept to protect active work."
                    } else if category == "Export" && url.pathExtension.lowercased() != "ipa" { protected = "Not an exported IPA." }
                    else { protected = nil }
                    result.append(RemovableStorageItem(url: url, name: policy.owner.map { "\(category) · \($0)" } ?? "\(category) · \(url.lastPathComponent)",
                        bytes: measureSizes ? SideKickStorageUsage.size(of: url) : 0, policy: policy, protectedReason: protected))
                }
            }
            return result.sorted { $0.bytes > $1.bytes }
        }.value
    }

    static func remove(_ item: RemovableStorageItem, downloads: GitHubUpdateDownloadStore, allowRetainedSource: Bool) async throws {
        guard !isRemovingFiles, !hasActiveOperations, !AppManager.shared.isActivelyManagingAnyApp, !downloads.jobs.values.contains(where: \.isDownloading) else {
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
            try validateContentsForRemoval(latest.url)
            try FileManager.default.removeItem(at: latest.url)
        }.value
    }

    static func cleanUnused(downloads: GitHubUpdateDownloadStore) async throws -> String {
        guard !isRemovingFiles, !hasActiveOperations, !AppManager.shared.isActivelyManagingAnyApp, !downloads.jobs.values.contains(where: \.isDownloading) else { throw StorageCleanupError.operationRunning }
        let candidates = try await items()
        var removed: Int64 = 0
        var count = 0
        var failures: [String] = []
        for item in candidates where item.protectedReason == nil && !item.policy.requiresSourceConfirmation && !item.name.hasPrefix("Export") {
            do { try await remove(item, downloads: downloads, allowRetainedSource: false); removed += item.bytes; count += 1 }
            catch { failures.append("\(item.name): \(error.localizedDescription)") }
        }
        // Clear HTTP response caches only after the active-work checks above.
        // This never touches downloaded IPAs, credentials, databases or exports.
        if !hasActiveOperations, !AppManager.shared.isActivelyManagingAnyApp,
           !downloads.jobs.values.contains(where: \.isDownloading) {
            URLCache.shared.removeAllCachedResponses()
        }
        let kept = candidates.filter { $0.policy.requiresSourceConfirmation || $0.protectedReason != nil }.count
        return "Removed \(count) items (\(ByteCountFormatter.string(fromByteCount: removed, countStyle: .file))). Kept \(kept) protected or required sources. Exports are kept."
            + (failures.isEmpty ? "" : "\n\n" + failures.joined(separator: "\n"))
    }

    static func performAutomaticMaintenance() async {
        guard DatabaseManager.shared.isStarted, !isRemovingFiles, !hasActiveOperations,
              !AppManager.shared.isActivelyManagingAnyApp else { return }
        isRemovingFiles = true
        defer { isRemovingFiles = false }
        do {
            let owners = try await payloadOwners()
            let candidates = try await items(includeExports: false, measureSizes: false)
            guard !hasActiveOperations, !AppManager.shared.isActivelyManagingAnyApp else { return }
            let cutoff = Date.now.addingTimeInterval(-24 * 60 * 60)
            let payloads = InstalledApp.appsDirectoryURL.appendingPathComponent("Payloads")
            let temporary = FileManager.default.temporaryDirectory
            // A failed install may have cached its source before its record was
            // saved. Give unreferenced sources a recovery window before pruning.
            let disposable = candidates.filter { item in
                guard item.protectedReason == nil, !item.policy.requiresSourceConfirmation else { return false }
                if item.url.deletingLastPathComponent().standardizedFileURL == temporary.standardizedFileURL { return true }
                guard item.url.deletingLastPathComponent().standardizedFileURL == payloads.standardizedFileURL,
                      let modified = try? item.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
                return modified < cutoff
            }
            let removedCount = await Task.detached(priority: .utility) {
                var removed = 0
                for item in disposable {
                    let root = item.url.deletingLastPathComponent()
                    guard (try? OwnedStoragePath.validate(item.url, inside: root)) != nil else { continue }
                    guard (try? validateContentsForRemoval(item.url)) != nil else { continue }
                    if (try? FileManager.default.removeItem(at: item.url)) != nil { removed += 1 }
                }
                let appsRoot = payloads.deletingLastPathComponent()
                for instance in (try? FileManager.default.contentsOfDirectory(at: appsRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                    guard !owners.instanceIDs.contains(instance.lastPathComponent),
                          isDisposableInstanceCache(instance, cutoff: cutoff),
                          (try? OwnedStoragePath.validate(instance, inside: appsRoot)) != nil,
                          (try? validateContentsForRemoval(instance)) != nil else { continue }
                    if (try? FileManager.default.removeItem(at: instance)) != nil { removed += 1 }
                }
                return removed
            }.value
            completedTemporaryPaths = completedTemporaryPaths.filter { FileManager.default.fileExists(atPath: $0) }
            try await IPAImportStore.shared.cleanupOrphanedManagedIPAs()
            if removedCount > 0 { NotificationCenter.default.post(name: .sideKickStorageDidChange, object: nil) }
        } catch {
            debugLog("[SideKick] Skipped automatic cleanup: \(error.localizedDescription)")
        }
    }

    nonisolated private static func isDisposableInstanceCache(_ url: URL, cutoff: Date) -> Bool {
        let name = url.lastPathComponent
        guard name.contains("."), name.allSatisfy({ $0.asciiValue != nil && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
              values.isDirectory == true, let modified = values.contentModificationDate, modified < cutoff,
              let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
              !children.isEmpty,
              children.allSatisfy({ ["App.app", "Refreshed.ipa", "signing_certificate.der"].contains($0.lastPathComponent) }) else { return false }
        // Custom profiles, entitlements, backup data and every unknown file
        // prevent automatic instance removal, even after an app is uninstalled.
        return children.contains { child in
            (child.lastPathComponent == "App.app" && FileManager.default.fileExists(atPath: child.appendingPathComponent("Info.plist").path))
                || (child.lastPathComponent == "Refreshed.ipa" && (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true)
        }
    }

    nonisolated private static func validateContentsForRemoval(_ url: URL) throws {
        guard (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { return }
        var failedToRead = false
        guard let contents = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey],
            errorHandler: { _, _ in failedToRead = true; return false }) else { throw StorageCleanupError.unsafePath }
        for case let child as URL in contents {
            if try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw StorageCleanupError.unsafePath }
        }
        if failedToRead { throw StorageCleanupError.unsafePath }
    }

    private static func payloadOwners() async throws -> (names: [String: String], identities: [String: Set<String>], instanceIDs: Set<String>) {
        guard DatabaseManager.shared.isStarted else { throw StorageCleanupError.protectedFile }
        let context = DatabaseManager.shared.viewContext
        return try await context.perform {
            var owners: [String: Set<String>] = [:]
            var identities: [String: Set<String>] = [:]
            var instanceIDs: Set<String> = []
            for app in try context.fetch(InstalledApp.fetchRequest()) where !app.isDeleted {
                instanceIDs.insert(app.resignedBundleIdentifier)
                if let signature = app.appBundleFingerprint {
                    owners[signature, default: []].insert(app.name)
                    identities[signature, default: []].insert(app.resignedBundleIdentifier)
                }
            }
            return (owners.mapValues { $0.sorted().joined(separator: ", ") }, identities, instanceIDs)
        }
    }
}
#endif
