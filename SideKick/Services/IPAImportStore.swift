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

    func fileURL(for app: ImportedIPA) throws -> URL {
        let url = directory.appendingPathComponent(app.fileName)
        guard fileManager.isReadableFile(atPath: url.path) else { throw IPAImportError.inaccessibleFile }
        return url
    }

    func importIPA(from sourceURL: URL) throws -> ImportedIPA {
        guard sourceURL.pathExtension.lowercased() == "ipa" else { throw IPAImportError.notAnIPA }
        let securityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if securityScoped { sourceURL.stopAccessingSecurityScopedResource() } }

        guard fileManager.isReadableFile(atPath: sourceURL.path) else { throw IPAImportError.inaccessibleFile }
        let metadata = try readMetadata(from: sourceURL)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let storedName = "\(UUID().uuidString).ipa"
        let destinationURL = directory.appendingPathComponent(storedName)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        do {
            var entries = try importedApps()
            if let previous = entries.first(where: { $0.bundleIdentifier == metadata.bundleIdentifier }) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(previous.fileName))
                entries.removeAll { $0.bundleIdentifier == metadata.bundleIdentifier }
            }

            let app = ImportedIPA(
                bundleIdentifier: metadata.bundleIdentifier,
                name: metadata.name,
                version: metadata.version,
                fileName: storedName,
                importedAt: .now,
                iconData: metadata.iconData
            )
            entries.insert(app, at: 0)
            try save(entries)
            return app
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    func delete(_ app: ImportedIPA) throws {
        var entries = try importedApps()
        entries.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        try save(entries)
        try? fileManager.removeItem(at: directory.appendingPathComponent(app.fileName))
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
