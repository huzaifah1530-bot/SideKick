import Foundation
import ZIPFoundation

extension Notification.Name {
    static let sideKickImportedIPAsDidChange = Notification.Name("SideKick.ImportedIPAsDidChange")
}

actor IPAImportStore {
    static let shared = IPAImportStore()
    private struct ExecutableMetadataExtractionStop: Error {}
    private static let maximumInfoPlistSize = 1 * 1024 * 1024
    private static let maximumIconSize = 4 * 1024 * 1024
    // LC_UUID is in the Mach-O header/load-command region. This cap bounds
    // retained executable bytes even for malformed binaries with huge commands.
    private static let maximumExecutableMetadataSize = 16 * 1024 * 1024
    private let fileManager: FileManager
    private let directory: URL
    private let indexURL: URL
    private var pendingManagedFiles: Set<String> = []
    private var storageRemovalActive = false
    private var activeFileReaders = 0

    func beginStorageRemoval() throws {
        guard !storageRemovalActive, pendingManagedFiles.isEmpty, activeFileReaders == 0 else { throw StorageCleanupError.operationRunning }
        storageRemovalActive = true
    }

    func endStorageRemoval() { storageRemovalActive = false }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("ImportedIPAs", isDirectory: true)
        indexURL = directory.appendingPathComponent("library.json")
    }

    func importedApps() throws -> [ImportedIPA] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        let data = try Data(contentsOf: indexURL)
        return try JSONDecoder().decode([ImportedIPA].self, from: data)
            .sorted { $0.importedAt > $1.importedAt }
    }

    func cleanupAbandonedTemporaryIPAImports() async {
        await SideKickStorageCleanup.performAutomaticMaintenance()
    }

    func prepareIPA(from sourceURL: URL, remoteSourceURL: URL? = nil) throws -> ImportedIPA {
        guard !storageRemovalActive else { throw StorageCleanupError.operationRunning }
        guard remoteSourceURL != nil || sourceURL.pathExtension.lowercased() == "ipa" else {
            throw IPAImportError.notAnIPA
        }
        let securityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if securityScoped { sourceURL.stopAccessingSecurityScopedResource() } }

        guard fileManager.isReadableFile(atPath: sourceURL.path) else { throw IPAImportError.inaccessibleFile }
        let metadata = try readMetadata(from: sourceURL)
        var managedFileName: String?
        let bookmarkData: Data?
        if remoteSourceURL == nil {
            do {
                bookmarkData = try sourceURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                throw IPAImportError.sourceBookmarkUnavailable
            }
        } else {
            bookmarkData = nil
            managedFileName = try retainManagedCopy(of: sourceURL, prefix: "url-import-")
        }
        let app = ImportedIPA(
            bundleIdentifier: metadata.bundleIdentifier,
            name: metadata.name,
            version: metadata.version,
            fileName: managedFileName,
            sourceBookmarkData: bookmarkData,
            sourceURLString: remoteSourceURL?.absoluteString,
            importedAt: .now,
            iconData: metadata.iconData,
            buildVersion: metadata.buildVersion, executableIdentity: metadata.executableIdentity,
            sourceCreatedAt: remoteSourceURL == nil ? sourceURLCreationDate(sourceURL) : nil
        )
        return app
    }

    /// Fallback for a .zip picked in Files: accepted only when it contains exactly one .ipa and
    /// nothing else (Finder's __MACOSX and .DS_Store entries are ignored). The IPA is kept as a
    /// managed copy because a file inside a zip can't be bookmarked.
    func prepareZippedIPA(from zipURL: URL) throws -> ImportedIPA {
        guard !storageRemovalActive else { throw StorageCleanupError.operationRunning }
        let securityScoped = zipURL.startAccessingSecurityScopedResource()
        defer { if securityScoped { zipURL.stopAccessingSecurityScopedResource() } }
        guard fileManager.isReadableFile(atPath: zipURL.path) else { throw IPAImportError.inaccessibleFile }
        let archive: Archive
        do { archive = try Archive(url: zipURL, accessMode: .read) }
        catch { throw IPAImportError.zipWithoutSingleIPA }
        let files = archive.filter { entry in
            guard entry.type == .file else { return false }
            let path = entry.path
            let name = (path as NSString).lastPathComponent
            return !path.hasPrefix("__MACOSX/") && !path.contains("/__MACOSX/") && name != ".DS_Store" && !name.hasPrefix("._")
        }
        guard files.count == 1, let entry = files.first, entry.path.lowercased().hasSuffix(".ipa") else {
            throw IPAImportError.zipWithoutSingleIPA
        }
        let extracted = fileManager.temporaryDirectory.appendingPathComponent("sidekick-zip-\(UUID().uuidString).ipa")
        defer { try? fileManager.removeItem(at: extracted) }
        _ = try archive.extract(entry, to: extracted)
        try Task.checkCancellation()
        // Treat it like a downloaded IPA so SideKick keeps its own copy.
        return try prepareIPA(from: extracted, remoteSourceURL: zipURL)
    }

    func prepareIPA(bookmarkData: Data) throws -> ImportedIPA {
        var isStale = false
        let sourceURL: URL
        do {
            sourceURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw IPAImportError.sourceFileMissing
        }
        guard sourceURL.pathExtension.lowercased() == "ipa" else {
            throw IPAImportError.sourceFileMissing
        }
        let securityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if securityScoped { sourceURL.stopAccessingSecurityScopedResource() } }
        guard fileManager.fileExists(atPath: sourceURL.path),
              fileManager.isReadableFile(atPath: sourceURL.path) else {
            throw IPAImportError.sourceFileMissing
        }
        let metadata = try readMetadata(from: sourceURL)
        let app = ImportedIPA(
            bundleIdentifier: metadata.bundleIdentifier,
            name: metadata.name,
            version: metadata.version,
            fileName: nil,
            sourceBookmarkData: bookmarkData,
            sourceURLString: nil,
            importedAt: .now,
            iconData: metadata.iconData,
            buildVersion: metadata.buildVersion, executableIdentity: metadata.executableIdentity,
            sourceCreatedAt: sourceURLCreationDate(sourceURL)
        )
        return app
    }

    func importIPA(from sourceURL: URL, remoteSourceURL: URL? = nil) throws -> ImportedIPA {
        let app = try prepareIPA(from: sourceURL, remoteSourceURL: remoteSourceURL)
        try saveImportedIPA(app)
        return app
    }

    func importRepositoryIPA(from sourceURL: URL, choice: GitHubImportChoice, tokenID: String?) throws -> ImportedIPA {
        let metadata = try readMetadata(from: sourceURL)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "repository-import-\(UUID().uuidString).ipa"
        let destination = directory.appendingPathComponent(fileName)
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            pendingManagedFiles.insert(fileName)
            return ImportedIPA(bundleIdentifier: metadata.bundleIdentifier, name: metadata.name,
                version: metadata.version, fileName: fileName, sourceBookmarkData: nil,
                sourceURLString: nil, importedAt: .now, iconData: metadata.iconData,
                buildVersion: metadata.buildVersion, executableIdentity: metadata.executableIdentity,
                githubUpdateKey: choice.candidate.updateKey,
                githubSourceIdentity: choice.configuration(bundleIdentifier: metadata.bundleIdentifier, tokenID: tokenID).sourceIdentity,
                githubRepositoryURL: choice.candidate.repositoryURL,
                githubImportConfiguration: choice.configuration(bundleIdentifier: metadata.bundleIdentifier, tokenID: tokenID))
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func migrateQueuedInstallations(_ installations: [String: [String]]) throws {
        for var ipa in try importedApps() where ipa.isUpdateQueued && ipa.queuedForInstalledAppID == nil {
            guard let copies = installations[ipa.bundleIdentifier], Set(copies).count == 1 else { continue }
            ipa.queuedForInstalledAppID = copies.first
            try saveImportedIPA(ipa)
        }
    }

    func importManagedIPA(from sourceURL: URL, expectedBundleIdentifiers: Set<String>, updateKey: String? = nil, repositoryURL: String? = nil, targetID: String? = nil, sourceIdentity: String? = nil, importConfiguration: GitHubUpdateConfiguration? = nil, queuedForUpdate: Bool = true) throws -> ImportedIPA {
        guard !storageRemovalActive else { throw StorageCleanupError.operationRunning }
        try Task.checkCancellation()
        let metadata = try readMetadata(from: sourceURL)
        let expected = expectedBundleIdentifiers.map { $0.lowercased() }
        guard expected.contains(metadata.bundleIdentifier.lowercased()) else {
            throw IPAImportError.bundleIdentifierMismatch(expectedBundleIdentifiers.sorted().joined(separator: " or "), metadata.bundleIdentifier)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "github-update-\(UUID().uuidString).ipa"
        let managedURL = directory.appendingPathComponent(fileName)
        do {
            try fileManager.copyItem(at: sourceURL, to: managedURL)
            let app = ImportedIPA(
                bundleIdentifier: metadata.bundleIdentifier,
                name: metadata.name,
                version: metadata.version,
                fileName: fileName,
                sourceBookmarkData: nil,
                sourceURLString: nil,
                importedAt: .now,
                iconData: metadata.iconData,
                buildVersion: metadata.buildVersion, executableIdentity: metadata.executableIdentity,
                isQueuedForUpdate: queuedForUpdate,
                queuedForInstalledAppID: targetID,
                githubUpdateKey: updateKey,
                githubSourceIdentity: sourceIdentity,
                githubRepositoryURL: repositoryURL,
                githubImportConfiguration: importConfiguration
            )
            try Task.checkCancellation()
            try saveImportedIPA(app)
            return app
        } catch {
            try? fileManager.removeItem(at: managedURL)
            throw error
        }
    }

    func importIPA(bookmarkData: Data) throws -> ImportedIPA {
        let app = try prepareIPA(bookmarkData: bookmarkData)
        try saveImportedIPA(app)
        return app
    }

    /// Complete only the package that was actually installed; another import may
    /// have replaced its library row while signing was in progress.
    func completeSeparateInstallation(_ installed: ImportedIPA) throws {
        guard var current = try importedApps().first(where: {
            $0.id == installed.id && $0.importedAt == installed.importedAt && $0.fileName == installed.fileName
        }), current.separateInstallationRequested == true else { return }
        current.separateInstallationRequested = false
        try saveImportedIPA(current)
    }

    func saveImportedIPA(_ app: ImportedIPA) throws {
        if let fileName = app.fileName,
           !fileManager.isReadableFile(atPath: directory.appendingPathComponent(fileName).path) {
            throw IPAImportError.sourceFileMissing
        }
        var entries = try importedApps()
        let previous = entries.filter { $0.id == app.id || ($0.bundleIdentifier == app.bundleIdentifier && $0.importedAt == app.importedAt) }
        entries = IPAImportIndex.replacing(app, in: entries)
        try save(entries)
        if let fileName = app.fileName { pendingManagedFiles.remove(fileName) }
        // Updating queue metadata must not delete the IPA it still references.
        for old in previous where old.fileName != app.fileName {
            if !entries.contains(where: { $0.fileName != nil && $0.fileName == old.fileName }) {
                removeLegacyStoredIPA(old)
            }
        }
        NotificationCenter.default.post(name: .sideKickImportedIPAsDidChange, object: nil)
    }

    func finishLiveContainerHandoff(_ completed: ImportedIPA) throws {
        guard var current = try importedApps().first(where: {
            $0.id == completed.id && $0.importedAt == completed.importedAt &&
                $0.githubUpdateKey == completed.githubUpdateKey && $0.githubSourceIdentity == completed.githubSourceIdentity
        }), current.liveContainerHandoffRequested == true else { return }
        current.liveContainerHandoffRequested = false
        try saveImportedIPA(current)
    }

    func isManagedIPAAvailable(_ app: ImportedIPA) -> Bool {
        guard let fileName = app.fileName else { return false }
        return fileManager.isReadableFile(atPath: directory.appendingPathComponent(fileName).path)
    }

    func cleanupOrphanedManagedIPAs() throws {
        let retainedNames = Set(try importedApps().compactMap(\.fileName)).union(pendingManagedFiles)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = url.deletingPathExtension().lastPathComponent
            let prefix = ["repository-import-", "github-update-", "url-import-"].first { name.hasPrefix($0) }
            // A repository import can be awaiting the user's final save. Keep
            // recent files even before the library index references them.
            guard url.pathExtension.lowercased() == "ipa", !retainedNames.contains(url.lastPathComponent),
                  let prefix, UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                  (try? OwnedStoragePath.validate(url, inside: directory)) != nil,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true, let modified = values.contentModificationDate,
                  modified < Date.now.addingTimeInterval(-24 * 60 * 60) else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    func fileURL(for requestedApp: ImportedIPA) async throws -> URL {
        guard !storageRemovalActive else { throw StorageCleanupError.operationRunning }
        activeFileReaders += 1
        defer { activeFileReaders -= 1 }
        // A caller may still hold a pre-migration value after another access has
        // already retained this URL source. Resolve the latest row by stable import
        // identity so later accesses immediately use the managed file.
        let app = try importedApps().first(where: {
            $0.bundleIdentifier == requestedApp.bundleIdentifier && $0.importedAt == requestedApp.importedAt
        }) ?? requestedApp
        let sourceURL: URL
        var securityScoped = false
        if let fileName = app.fileName {
            sourceURL = directory.appendingPathComponent(fileName)
        } else if let bookmarkData = app.sourceBookmarkData {
            var isStale = false
            do {
                sourceURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                throw IPAImportError.sourceFileMissing
            }
            securityScoped = sourceURL.startAccessingSecurityScopedResource()
            do {
                guard fileManager.isReadableFile(atPath: sourceURL.path) else {
                    throw IPAImportError.sourceFileMissing
                }
                let metadata = try readMetadata(from: sourceURL)
                guard metadataMatches(metadata, reviewed: app) else {
                    throw IPAImportError.sourceChanged
                }
            } catch {
                if securityScoped { sourceURL.stopAccessingSecurityScopedResource() }
                securityScoped = false
                throw error
            }
        } else if let sourceURLString = app.sourceURLString,
                  let url = URL(string: sourceURLString), url.scheme?.lowercased() == "https" {
            let (downloadURL, response) = try await BuzzheavierClient().download(from: url)
            defer { try? fileManager.removeItem(at: downloadURL) }
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw IPAImportError.sourceFileMissing
            }
            guard fileManager.isReadableFile(atPath: downloadURL.path) else {
                throw IPAImportError.sourceFileMissing
            }
            try Task.checkCancellation()
            // Another caller may have completed migration during this network
            // request. Prefer its retained copy and avoid creating a second file.
            if let latest = try importedApps().first(where: {
                $0.bundleIdentifier == app.bundleIdentifier && $0.importedAt == app.importedAt
            }), let latestFileName = latest.fileName {
                let retainedURL = directory.appendingPathComponent(latestFileName)
                guard fileManager.isReadableFile(atPath: retainedURL.path) else {
                    throw IPAImportError.sourceFileMissing
                }
                return try makeValidatedTemporaryCopy(
                    of: retainedURL,
                    reviewed: app,
                    checkCancellationAfterCopy: true,
                    translateUnexpectedErrors: true
                )
            }
            let metadata = try readMetadata(from: downloadURL)
            guard metadataMatches(metadata, reviewed: app) else { throw IPAImportError.sourceChanged }

            // Older library entries stored only the URL. Save a managed copy only
            // after its reviewed identity matches, then update the latest index row
            // so queue edits made while the download was suspended are preserved.
            let fileName = try retainManagedCopy(of: downloadURL, prefix: "url-import-")
            let managedURL = directory.appendingPathComponent(fileName)
            do {
                try Task.checkCancellation()

                var entries = try importedApps()
                guard let index = entries.firstIndex(where: {
                    $0.bundleIdentifier == app.bundleIdentifier && $0.importedAt == app.importedAt
                }) else {
                    pendingManagedFiles.remove(fileName)
                    try? fileManager.removeItem(at: managedURL)
                    throw IPAImportError.sourceFileMissing
                }
                entries[index].fileName = fileName
                do {
                    try save(entries)
                    pendingManagedFiles.remove(fileName)
                    NotificationCenter.default.post(name: .sideKickImportedIPAsDidChange, object: nil)
                } catch {
                    pendingManagedFiles.remove(fileName)
                    try? fileManager.removeItem(at: managedURL)
                    throw error
                }
            } catch {
                try? fileManager.removeItem(at: managedURL)
                pendingManagedFiles.remove(fileName)
                throw error
            }

            return try makeValidatedTemporaryCopy(
                of: managedURL,
                reviewed: app,
                checkCancellationBeforeCopy: true,
                checkCancellationAfterCopy: true,
                translateUnexpectedErrors: true
            )
        } else {
            throw IPAImportError.sourceFileMissing
        }
        defer { if securityScoped { sourceURL.stopAccessingSecurityScopedResource() } }
        guard fileManager.isReadableFile(atPath: sourceURL.path) else { throw IPAImportError.sourceFileMissing }
        return try makeValidatedTemporaryCopy(of: sourceURL, reviewed: app)
    }

    /// Only the running self binary is authoritative after an interrupted self-install.
    func removeInstalledSelfUpdates(targetID: String, version: String, build: String, executableIdentity: String) throws {
        for ipa in IPAImportIndex.completedSelfUpdates(in: try importedApps(), targetID: targetID,
            version: version, build: build, executableIdentity: executableIdentity) {
            try delete(ipa)
        }
    }

    func delete(_ app: ImportedIPA) throws {
        var entries = try importedApps()
        let removed = entries.filter { $0.id == app.id && $0.importedAt == app.importedAt }
        entries.removeAll { $0.id == app.id && $0.importedAt == app.importedAt }
        try save(entries)
        for old in removed where !entries.contains(where: { $0.fileName != nil && $0.fileName == old.fileName }) {
            removeLegacyStoredIPA(old)
        }
        discardPreparedIPA(app)
        NotificationCenter.default.post(name: .sideKickImportedIPAsDidChange, object: nil)
    }

    /// Deletes SideKick-managed queued IPAs for one LiveContainer guest target.
    /// The target ID is the stable LiveContainer guest ID, not the app bundle ID.
    func deleteQueuedUpdates(forGuestTargetID targetID: String) throws {
        let queued = try importedApps().filter { $0.queuedForInstalledAppID == targetID }
        for app in queued { try delete(app) }
    }

    func discardPreparedIPA(_ app: ImportedIPA) {
        guard let fileName = app.fileName else { return }
        guard let entries = try? importedApps(), !entries.contains(where: { $0.fileName == fileName }) else { return }
        pendingManagedFiles.remove(fileName)
        try? fileManager.removeItem(at: directory.appendingPathComponent(fileName))
    }

    private func sourceURLCreationDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    private func removeLegacyStoredIPA(_ app: ImportedIPA) {
        guard let fileName = app.fileName else { return }
        pendingManagedFiles.remove(fileName)
        try? fileManager.removeItem(at: directory.appendingPathComponent(fileName))
    }

    private func save(_ entries: [ImportedIPA]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: indexURL, options: .atomic)
    }

    private func readMetadata(from ipaURL: URL) throws -> (bundleIdentifier: String, name: String, version: String, iconData: Data?, buildVersion: String?, executableIdentity: String?) {
        let archive: Archive
        do {
            archive = try Archive(url: ipaURL, accessMode: .read)
        } catch {
            throw IPAImportError.invalidArchive
        }

        let appRoots = Set(archive.compactMap { item -> String? in
            let components = item.path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count >= 3, components[0] == "Payload",
                  components[1].hasSuffix(".app"), components[1].count > 4 else { return nil }
            return String(components[1])
        })
        guard appRoots.count <= 1 else { throw IPAImportError.ambiguousAppBundles }
        guard let appRoot = appRoots.first,
              let entry = archive.first(where: { $0.path == "Payload/\(appRoot)/Info.plist" }) else {
            throw IPAImportError.missingAppBundle
        }

        guard entry.uncompressedSize >= 0,
              entry.uncompressedSize <= Int64(Self.maximumInfoPlistSize) else {
            throw IPAImportError.invalidArchive
        }
        var plistData = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                guard chunk.count <= Self.maximumInfoPlistSize - plistData.count else {
                    throw IPAImportError.invalidArchive
                }
                plistData.append(chunk)
            }
        } catch {
            throw IPAImportError.invalidArchive
        }

        guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw IPAImportError.invalidArchive
        }
        guard let bundleIdentifier = plist["CFBundleIdentifier"] as? String, !bundleIdentifier.isEmpty else {
            throw IPAImportError.missingBundleIdentifier
        }

        let appBundleName = URL(fileURLWithPath: entry.path).deletingLastPathComponent().lastPathComponent
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? appBundleName.replacingOccurrences(of: ".app", with: "")
        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
            ?? "Unknown"

        let appPath = "Payload/\(appRoot)"
        let iconNames = (plist["CFBundleIcons"] as? [String: Any])
            .flatMap { $0["CFBundlePrimaryIcon"] as? [String: Any] }?["CFBundleIconFiles"] as? [String] ?? []
        let iconEntry = iconNames.reversed().lazy.compactMap { iconName -> ZIPFoundation.Entry? in
            let path = iconName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty, !path.split(separator: "/").contains("..") else { return nil }
            let nsPath = path as NSString
            let ext = nsPath.pathExtension
            let stem = ext.isEmpty ? path : nsPath.deletingPathExtension
            let extensions = ext.isEmpty ? ["", ".png", ".jpg", ".jpeg"] : [".\(ext)"]
            let names = [stem, "\(stem)@2x", "\(stem)@3x"].flatMap { base in extensions.map { base + $0 } }
            return names.lazy.compactMap { candidate in
                archive.first { $0.path == "\(appPath)/\(candidate)" }
            }.first
        }.first
        var iconData: Data?
        if let iconEntry, iconEntry.uncompressedSize >= 0,
           iconEntry.uncompressedSize <= Int64(Self.maximumIconSize) {
            var data = Data()
            do {
                try archive.extract(iconEntry) { chunk in
                    guard chunk.count <= Self.maximumIconSize - data.count else {
                        throw IPAImportError.invalidArchive
                    }
                    data.append(chunk)
                }
                iconData = data.isEmpty ? nil : data
            } catch {
                iconData = nil
            }
        }
        var executableIdentity: String?
        if let executable = plist["CFBundleExecutable"] as? String,
           !executable.contains("/"), !executable.contains("\\"),
           let binary = archive.first(where: { $0.path == String(entry.path.dropLast("Info.plist".count)) + executable }) {
            var data = Data()
            do {
                _ = try archive.extract(binary) { chunk in
                    var chunkOffset = 0
                    while chunkOffset < chunk.count {
                        if data.count < 32 {
                            let end = min(chunk.count, chunkOffset + 32 - data.count)
                            data.append(chunk[chunkOffset..<end])
                            chunkOffset = end
                            guard data.count == 32 else { continue }
                        }

                        guard let metadataSize = GitHubExecutableIdentity.metadataRegionSize(
                            data,
                            maximumSize: Self.maximumExecutableMetadataSize
                        ) else {
                            throw ExecutableMetadataExtractionStop()
                        }
                        let end = min(chunk.count, chunkOffset + metadataSize - data.count)
                        data.append(chunk[chunkOffset..<end])
                        chunkOffset = end
                        guard data.count == metadataSize else { continue }

                        executableIdentity = GitHubExecutableIdentity.read(data)
                        data.removeAll(keepingCapacity: false)
                        throw ExecutableMetadataExtractionStop()
                    }
                }
            } catch is ExecutableMetadataExtractionStop {
                // Stop ZIP extraction once the Mach-O load-command region is read.
            } catch {
                executableIdentity = nil
                data.removeAll(keepingCapacity: false)
            }
            if executableIdentity == nil {
                executableIdentity = GitHubExecutableIdentity.read(data)
            }
        }
        return (bundleIdentifier, name, version, iconData, plist["CFBundleVersion"] as? String, executableIdentity)
    }

    private func retainManagedCopy(of sourceURL: URL, prefix: String) throws -> String {
        try Task.checkCancellation()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(prefix)\(UUID().uuidString).ipa"
        let destination = directory.appendingPathComponent(fileName)
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            try Task.checkCancellation()
            pendingManagedFiles.insert(fileName)
            return fileName
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func temporaryIPAURL() -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(
            "sidekick-import-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).ipa"
        )
    }

    private func makeValidatedTemporaryCopy(
        of sourceURL: URL,
        reviewed app: ImportedIPA,
        checkCancellationBeforeCopy: Bool = false,
        checkCancellationAfterCopy: Bool = false,
        translateUnexpectedErrors: Bool = false
    ) throws -> URL {
        let temporaryURL = temporaryIPAURL()
        var keepTemporary = false
        defer {
            if !keepTemporary { try? fileManager.removeItem(at: temporaryURL) }
        }

        do {
            if checkCancellationBeforeCopy { try Task.checkCancellation() }
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            if checkCancellationAfterCopy { try Task.checkCancellation() }
        } catch {
            if error is CancellationError { throw error }
            throw IPAImportError.sourceFileMissing
        }

        do {
            let copiedMetadata = try readMetadata(from: temporaryURL)
            guard metadataMatches(copiedMetadata, reviewed: app) else { throw IPAImportError.sourceChanged }
        } catch {
            if translateUnexpectedErrors,
               !(error is IPAImportError), !(error is CancellationError) {
                throw IPAImportError.sourceFileMissing
            }
            throw error
        }

        keepTemporary = true
        return temporaryURL
    }

    private func metadataMatches(
        _ metadata: (bundleIdentifier: String, name: String, version: String, iconData: Data?, buildVersion: String?, executableIdentity: String?),
        reviewed app: ImportedIPA
    ) -> Bool {
        metadata.bundleIdentifier.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame
            && metadata.version == app.version
            && (app.buildVersion == nil || metadata.buildVersion == app.buildVersion)
            && (app.executableIdentity == nil || metadata.executableIdentity == app.executableIdentity)
    }
}
