import CoreData
import Foundation
import ZIPFoundation

struct ManagedStorageReview: Sendable {
    let url: URL
    let warning: String?
    let requiresRestart: Bool
    var deferredURLs: [URL] = []
}

/// Explicit user deletion is broader than automatic cleanup. Both remain confined
/// to SideKick-owned roots; links are never followed while removing directories.
enum DeferredStorageRemoval {
    private static let key = "sidekick.storage.pending-removals"

    static func roots() -> [URL] {
        let manager = FileManager.default
        var roots = [manager.urls(for: .documentDirectory, in: .userDomainMask)[0],
                     manager.urls(for: .libraryDirectory, in: .userDomainMask)[0], manager.temporaryDirectory]
        if let group = Bundle.main.altstoreAppGroup,
           let url = manager.containerURL(forSecurityApplicationGroupIdentifier: group) { roots.append(url) }
        return roots.map(\.standardizedFileURL)
    }

    static func validate(_ url: URL) throws -> URL {
        guard let root = roots().first(where: { url.standardizedFileURL.path.hasPrefix($0.path + "/") }) else {
            throw StorageCleanupError.unsafePath
        }
        try OwnedStoragePath.validate(url, inside: root)
        if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            var failed = false
            guard let contents = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey],
                errorHandler: { _, _ in failed = true; return false }) else { throw StorageCleanupError.unsafePath }
            for case let child as URL in contents {
                if try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { contents.skipDescendants() }
            }
            if failed { throw StorageCleanupError.unsafePath }
        }
        return root
    }

    static func queue(_ url: URL) {
        var pending = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !pending.contains(url.path) { pending.append(url.path) }
        UserDefaults.standard.set(pending, forKey: key)
    }

    static func applyBeforeDatabaseStart() {
        let pending = UserDefaults.standard.stringArray(forKey: key) ?? []
        UserDefaults.standard.removeObject(forKey: key)
        var failed: [String] = []
        for path in pending {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                _ = try validate(url)
                if let id = Bundle.main.bundleIdentifier {
                    let preferences = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences/" + id + ".plist")
                    if contains(url, preferences) { UserDefaults.standard.removePersistentDomain(forName: id) }
                }
                try FileManager.default.removeItem(at: url)
            } catch {
                failed.append(path)
                debugLog("[SideKick] Deferred storage deletion failed: \(error.localizedDescription)")
            }
        }
        if !failed.isEmpty { UserDefaults.standard.set(failed, forKey: key) }
    }

    static func contains(_ parent: URL, _ child: URL) -> Bool {
        let a = parent.standardizedFileURL.path
        let b = child.standardizedFileURL.path
        return a == b || b.hasPrefix(a + "/")
    }
}

@MainActor
enum ManagedStorageFiles {
    static func review(_ url: URL) async throws -> ManagedStorageReview {
        _ = try DeferredStorageRemoval.validate(url)
        guard DatabaseManager.shared.isStarted else { throw StorageCleanupError.protectedFile }
        let context = DatabaseManager.shared.viewContext
        let references = try await context.perform { () -> ([StorageInstalledVersion], [(URL, String)], [URL]) in
            let apps = try context.fetch(InstalledApp.fetchRequest())
            var important: [(URL, String)] = []
            var versions: [StorageInstalledVersion] = []
            for app in apps {
                versions.append(StorageInstalledVersion(identifiers: [app.bundleIdentifier, app.resignedBundleIdentifier],
                    name: app.name, version: app.version, build: app.buildVersion))
                let reason = "Current retained build for \(app.name) \(app.version) (\(app.buildVersion)). Removing it may require reimporting the original IPA before refresh or recovery."
                important.append((app.fileURL.resolvingSymlinksInPath(), reason))
                important.append((app.fileURL, reason))
                if let hash = app.appBundleFingerprint {
                    important.append((InstalledApp.appsDirectoryURL.appendingPathComponent("Payloads/" + hash), reason))
                }
                if let backup = FileManager.default.backupDirectoryURL(for: app), FileManager.default.fileExists(atPath: backup.path) {
                    important.append((backup, "Saved backup for \(app.name). Removing it permanently removes that recovery copy."))
                }
            }
            let databases = DatabaseManager.shared.persistentContainer.persistentStoreCoordinator.persistentStores.compactMap(\.url)
            return (versions, important, databases)
        }
        var reasons = Set(references.1.compactMap { path, reason in
            DeferredStorageRemoval.contains(url, path) || DeferredStorageRemoval.contains(path, url) ? reason : nil
        })
        let database = references.2.contains {
            DeferredStorageRemoval.contains(url, $0) || url.path.hasPrefix($0.path + "-")
        }
        if database { reasons.insert("This contains the active app database or one of its sidecars. Deleting it resets the whole affected database on SideKick's next launch, including its saved records.") }
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let preferences = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences/" + (Bundle.main.bundleIdentifier ?? "com.sidekick.app") + ".plist")
        let isPreferences = DeferredStorageRemoval.contains(url, preferences)
        let records = ["ImportedIPAs/library.json", "SideKick/SigningAccounts.json", "SideKick/ImportedCertificates.json",
                       "SideKick/GitHubUpdates/apps.json", "LiveContainer/state.json"].map { support.appendingPathComponent($0) } + [preferences]
        let containsRecords = records.contains(where: { manager.fileExists(atPath: $0.path) && DeferredStorageRemoval.contains(url, $0) })
        if containsRecords {
            reasons.insert("This contains app settings, signing configuration or saved library records. It will be deleted on the next launch; you may need to set it up again.")
        }
        if url.pathExtension.lowercased() == "ipa", let metadata = try await archiveMetadata(url),
           let owner = StorageArchiveImportance.owner(bundleID: metadata.0, version: metadata.1, build: metadata.2, installed: references.0) {
            reasons.insert("This IPA matches the current installed build of \(owner). Removing it may require downloading that build again.")
        }
        // Directories must carry warnings for important descendants too, including
        // downloaded current-version IPAs not used as a signing payload yet.
        if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
           let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let child as URL in files {
                if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    files.skipDescendants()
                    continue
                }
                guard child.pathExtension.lowercased() == "ipa" else { continue }
                if let metadata = try await archiveMetadata(child),
                   let owner = StorageArchiveImportance.owner(bundleID: metadata.0, version: metadata.1, build: metadata.2, installed: references.0) {
                    reasons.insert("Contains the IPA for \(owner)'s current installed build.")
                }
            }
        }
        var deferred = [url]
        if let store = references.2.first(where: { url == $0 || url.path.hasPrefix($0.path + "-") }) {
            deferred = [store] + ["-wal", "-shm", "-journal"].map { URL(fileURLWithPath: store.path + $0) }
        }
        return ManagedStorageReview(url: url, warning: reasons.isEmpty ? nil : reasons.sorted().joined(separator: "\n\n"),
                                    requiresRestart: database || isPreferences || containsRecords, deferredURLs: deferred)
    }

    static func remove(_ review: ManagedStorageReview, downloads: GitHubUpdateDownloadStore, confirmed: Bool) async throws -> Bool {
        try SideKickStorageCleanup.beginManualRemoval(downloads: downloads)
        defer { SideKickStorageCleanup.endManualRemoval() }
        try await IPAImportStore.shared.beginStorageRemoval()
        do {
            let result = try await removeWhileLocked(review, confirmed: confirmed)
            await IPAImportStore.shared.endStorageRemoval()
            return result
        } catch {
            await IPAImportStore.shared.endStorageRemoval()
            throw error
        }
    }

    private static func removeWhileLocked(_ review: ManagedStorageReview, confirmed: Bool) async throws -> Bool {
        let latest = try await self.review(review.url)
        guard latest.warning == nil || (confirmed && latest.warning == review.warning) else { throw StorageCleanupError.protectedFile }
        _ = try DeferredStorageRemoval.validate(latest.url)
        if latest.requiresRestart {
            for url in latest.deferredURLs { DeferredStorageRemoval.queue(url) }
            NotificationCenter.default.post(name: .sideKickStorageDidChange, object: nil)
            return true
        }
        let imported = try await IPAImportStore.shared.importedApps()
        let importRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ImportedIPAs")
        for app in imported {
            guard let name = app.fileName, DeferredStorageRemoval.contains(latest.url, importRoot.appendingPathComponent(name)) else { continue }
            try await IPAImportStore.shared.delete(app)
        }
        if FileManager.default.fileExists(atPath: latest.url.path) {
            _ = try DeferredStorageRemoval.validate(latest.url)
            try FileManager.default.removeItem(at: latest.url)
        }
        NotificationCenter.default.post(name: .sideKickStorageDidChange, object: nil)
        return latest.requiresRestart
    }

    private static func archiveMetadata(_ url: URL) async throws -> (String, String, String?)? {
        await Task.detached(priority: .utility) { () -> (String, String, String?)? in
            guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
            let entries = archive.filter { entry in
                let parts = entry.path.split(separator: "/")
                return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
            }
            guard entries.count == 1, let entry = entries.first, entry.uncompressedSize <= 1_048_576 else { return nil }
            var data = Data()
            guard (try? archive.extract(entry, consumer: { chunk in
                guard data.count + chunk.count <= 1_048_576 else { throw StorageCleanupError.unsafePath }
                data.append(chunk)
            })) != nil,
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let identifier = plist["CFBundleIdentifier"] as? String,
                  let version = plist["CFBundleShortVersionString"] as? String else { return nil }
            return (identifier, version, plist["CFBundleVersion"] as? String)
        }.value
    }
}
