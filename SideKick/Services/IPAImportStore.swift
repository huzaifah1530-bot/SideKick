import Foundation
import ZIPFoundation

extension Notification.Name {
    static let sideKickImportedIPAsDidChange = Notification.Name("SideKick.ImportedIPAsDidChange")
}

actor IPAImportStore {
    static let shared = IPAImportStore()
    private let fileManager: FileManager
    private let directory: URL
    private let indexURL: URL
    private var pendingManagedFiles: Set<String> = []

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
        guard remoteSourceURL != nil || sourceURL.pathExtension.lowercased() == "ipa" else {
            throw IPAImportError.notAnIPA
        }
        let securityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if securityScoped { sourceURL.stopAccessingSecurityScopedResource() } }

        guard fileManager.isReadableFile(atPath: sourceURL.path) else { throw IPAImportError.inaccessibleFile }
        let metadata = try readMetadata(from: sourceURL)
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
        }
        let app = ImportedIPA(
            bundleIdentifier: metadata.bundleIdentifier,
            name: metadata.name,
            version: metadata.version,
            fileName: nil,
            sourceBookmarkData: bookmarkData,
            sourceURLString: remoteSourceURL?.absoluteString,
            importedAt: .now,
            iconData: metadata.iconData,
            buildVersion: metadata.buildVersion, executableIdentity: metadata.executableIdentity,
            sourceCreatedAt: remoteSourceURL == nil ? sourceURLCreationDate(sourceURL) : nil
        )
        return app
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

    func importManagedIPA(from sourceURL: URL, expectedBundleIdentifiers: Set<String>, updateKey: String? = nil, repositoryURL: String? = nil, targetID: String? = nil, sourceIdentity: String? = nil) throws -> ImportedIPA {
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
                queuedForInstalledAppID: targetID,
                githubUpdateKey: updateKey,
                githubSourceIdentity: sourceIdentity,
                githubRepositoryURL: repositoryURL
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

    func saveImportedIPA(_ app: ImportedIPA) throws {
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

    func isManagedIPAAvailable(_ app: ImportedIPA) -> Bool {
        guard let fileName = app.fileName else { return false }
        return fileManager.isReadableFile(atPath: directory.appendingPathComponent(fileName).path)
    }

    func cleanupOrphanedManagedIPAs() throws {
        let retainedNames = Set(try importedApps().compactMap(\.fileName)).union(pendingManagedFiles)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = url.deletingPathExtension().lastPathComponent
            let prefix = ["repository-import-", "github-update-"].first { name.hasPrefix($0) }
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

    func fileURL(for app: ImportedIPA) async throws -> URL {
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
        } else if let sourceURLString = app.sourceURLString,
                  let url = URL(string: sourceURLString), url.scheme?.lowercased() == "https" {
            let (downloadURL, response) = try await BuzzheavierClient().download(from: url)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                try? fileManager.removeItem(at: downloadURL)
                throw IPAImportError.sourceFileMissing
            }
            guard fileManager.isReadableFile(atPath: downloadURL.path) else {
                try? fileManager.removeItem(at: downloadURL)
                throw IPAImportError.sourceFileMissing
            }
            // URLSession has already materialized this temporary download.
            // Return it directly; callers own and remove this temporary file.
            return downloadURL
        } else {
            throw IPAImportError.sourceFileMissing
        }
        defer { if securityScoped { sourceURL.stopAccessingSecurityScopedResource() } }
        guard fileManager.isReadableFile(atPath: sourceURL.path) else { throw IPAImportError.sourceFileMissing }
        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("sidekick-import-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
            .appendingPathExtension("ipa")
        do {
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            return temporaryURL
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw IPAImportError.sourceFileMissing
        }
    }

    func delete(_ app: ImportedIPA) throws {
        var entries = try importedApps()
        entries.removeAll { $0.id == app.id && $0.importedAt == app.importedAt }
        try save(entries)
        if !entries.contains(where: { $0.fileName != nil && $0.fileName == app.fileName }) {
            removeLegacyStoredIPA(app)
        }
        NotificationCenter.default.post(name: .sideKickImportedIPAsDidChange, object: nil)
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

        guard let entry = archive.first(where: { item in
            item.path.hasPrefix("Payload/") &&
            item.path.contains(".app/") &&
            item.path.hasSuffix(".app/Info.plist")
        }) else {
            throw IPAImportError.missingAppBundle
        }

        var plistData = Data()
        do {
            _ = try archive.extract(entry) { chunk in plistData.append(chunk) }
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

        let appPath = URL(fileURLWithPath: entry.path).deletingLastPathComponent().path
        let iconNames = (plist["CFBundleIcons"] as? [String: Any])
            .flatMap { $0["CFBundlePrimaryIcon"] as? [String: Any] }?["CFBundleIconFiles"] as? [String] ?? []
        let iconEntry = iconNames.reversed().lazy.compactMap { iconName in
            archive.first { $0.path == "\(appPath)/\(iconName).png" || $0.path == "\(appPath)/\(iconName)@2x.png" || $0.path == "\(appPath)/\(iconName)@3x.png" }
        }.first
        var iconData: Data?
        if let iconEntry {
            var data = Data()
            try? archive.extract(iconEntry) { data.append($0) }
            iconData = data.isEmpty ? nil : data
        }
        var executableIdentity: String?
        if let executable = plist["CFBundleExecutable"] as? String,
           !executable.contains("/"), !executable.contains("\\"),
           let binary = archive.first(where: { $0.path == String(entry.path.dropLast("Info.plist".count)) + executable }) {
            var data = Data()
            _ = try archive.extract(binary) { data.append($0) }
            executableIdentity = GitHubExecutableIdentity.read(data)
        }
        return (bundleIdentifier, name, version, iconData, plist["CFBundleVersion"] as? String, executableIdentity)
    }
}
