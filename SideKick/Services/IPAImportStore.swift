import Foundation
import ZIPFoundation

actor IPAImportStore {
    private let fileManager: FileManager
    private let directory: URL
    private let indexURL: URL

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

    func cleanupAbandonedTemporaryIPAImports() {
        let temporaryRoot = fileManager.temporaryDirectory
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
        for candidate in candidates {
            guard let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  values.isDirectory == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff,
                  let contents = try? fileManager.contentsOfDirectory(
                    at: candidate,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            let isAbandonedIPAImport = contents.count == 1
                && contents[0].pathExtension.lowercased() == "ipa"
                && (try? contents[0].resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            let containsStagedApp = contents.contains { item in
                item.lastPathComponent == "App.app"
                    && (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            let containsStagedIPA = contents.contains { item in
                item.lastPathComponent == "App.ipa"
                    && (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }

            // Failed SideStore pipelines skip CleanStagedAppOperation and can
            // leave a full extracted app plus its generated IPA in this unique
            // temporary directory. Prune only old folders with those markers.
            guard isAbandonedIPAImport || containsStagedApp || containsStagedIPA else { continue }
            try? fileManager.removeItem(at: candidate)
        }
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
            iconData: metadata.iconData
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
            iconData: metadata.iconData
        )
        return app
    }

    func importIPA(from sourceURL: URL, remoteSourceURL: URL? = nil) throws -> ImportedIPA {
        let app = try prepareIPA(from: sourceURL, remoteSourceURL: remoteSourceURL)
        try saveImportedIPA(app)
        return app
    }

    func importManagedIPA(from sourceURL: URL, expectedBundleIdentifiers: Set<String>) throws -> ImportedIPA {
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
                iconData: metadata.iconData
            )
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
        if let previous = entries.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            removeLegacyStoredIPA(previous)
            entries.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        }
        entries.insert(app, at: 0)
        try save(entries)
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
            .appendingPathComponent(UUID().uuidString)
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
        entries.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        try save(entries)
        removeLegacyStoredIPA(app)
    }

    private func removeLegacyStoredIPA(_ app: ImportedIPA) {
        guard let fileName = app.fileName else { return }
        try? fileManager.removeItem(at: directory.appendingPathComponent(fileName))
    }

    private func save(_ entries: [ImportedIPA]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: indexURL, options: .atomic)
    }

    private func readMetadata(from ipaURL: URL) throws -> (bundleIdentifier: String, name: String, version: String, iconData: Data?) {
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
        return (bundleIdentifier, name, version, iconData)
    }
}
