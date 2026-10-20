import CoreData
import Foundation
import SideSign

/// Moves SideKick to a copy signed by another team (for example an imported certificate).
/// The two installs can't share storage, so data travels through a folder the user picks
/// in Files. Secrets (Apple sign-ins, GitHub tokens, certificates) stay in each Keychain.
struct SideKickTransferManifest: Codable, Sendable {
    static let fileName = "SideKickTransfer.json"
    static let currentFormat = 1

    var format = Self.currentFormat
    var exportedAt: Date
    /// The exporting SideKick's installed bundle ID, so the new copy can offer to delete it.
    var sourceBundleIdentifier: String
    var apps: [App]
    var library: [LibraryIPA]
    /// Update sources for LiveContainer apps; their IDs don't depend on SideKick's team.
    var liveContainerSources: [GitHubUpdateConfiguration]
    var settings: [String: Setting]
    /// Apps offloaded in the old copy. Their backups stay there and are lost if it's deleted.
    var offloadedApps: [String]? = nil
    /// Apple certificates, encrypted with the password chosen at export. Optional.
    var appleCertificates: [TransferredAppleCertificate]? = nil

    struct App: Codable, Sendable {
        var name: String
        var originalBundleIdentifier: String
        var installedBundleIdentifier: String
        var version: String
        var buildVersion: String
        /// Relative to the transfer folder. `nil` when the signed copy wasn't cached.
        var ipaPath: String?
        /// The tracked GitHub source, including the installed-build receipt.
        var github: GitHubUpdateConfiguration?

        /// SideStore adds the Apple team to bundle IDs it signs. Such an app can't be upgraded
        /// by another team, so the new copy installs it separately and its data stays behind.
        var keepsDataWhenReinstalled: Bool { installedBundleIdentifier == originalBundleIdentifier }
    }

    struct LibraryIPA: Codable, Sendable {
        var ipaPath: String
        var entry: ImportedIPA
    }

    enum Setting: Codable, Sendable, Equatable {
        case bool(Bool)
        case string(String)
    }
}

struct SideKickTransferImportResult: Sendable {
    var importedApps: [String]
    var importedLibraryIPAs: Int
    var restoredSources: Int
    var skipped: [String]
    var sourceBundleIdentifier: String
    /// Apps that install as new, empty copies; their data stays in the old installation.
    var appsWithoutData: [String] = []
    var offloadedApps: [String] = []
    var restoredCertificates = 0
    var certificatesNeedPassword = false
}

enum SideKickTransferError: LocalizedError {
    case notATransferFolder
    case unsupportedFormat
    case folderUnavailable
    case nothingToExport
    case sameInstallation
    case notSideKick
    case wrongCertificatePassword

    var errorDescription: String? {
        switch self {
        case .notATransferFolder:
            return "This folder doesn’t contain SideKick transfer data. Choose the “SideKick Transfer” folder you exported."
        case .unsupportedFormat:
            return "This transfer was made by a newer SideKick. Update this copy, then try again."
        case .folderUnavailable:
            return "SideKick couldn’t open that folder. Choose a folder in On My iPhone or iCloud Drive."
        case .nothingToExport:
            return "There’s nothing to transfer yet."
        case .sameInstallation:
            return "This data came from this same SideKick, so there’s nothing to import."
        case .notSideKick:
            return "That app isn’t a SideKick install, so it wasn’t deleted."
        case .wrongCertificatePassword:
            return "That password doesn’t open the transferred certificates. Nothing else was changed; try the password you chose when exporting."
        }
    }
}

@MainActor
enum SideKickTransferService {
    /// UserDefaults copied across. Per-app offload and transfer state stays behind on purpose:
    /// it describes backups that only exist inside the old copy.
    /// Setup state is deliberately not copied: the new copy still needs its own pairing file.
    private static let settingKeys = [
        "sidekick.appearance.mode", "sidekick.appearance.accent", "sidekick.appearance.matchAppIcon"
    ]

    // MARK: Separate copy

    /// The bundle ID for a SideKick copy signed with `profile`.
    ///
    /// With a single-App-ID profile the copy must use exactly that App ID. If its bundle ID
    /// differs from the signed application-identifier, iOS can't deliver files from the
    /// document picker, so pairing files, IPAs and transfer folders can't be imported.
    /// Wildcard profiles allow any ID, so the copy keeps a recognisable team-suffixed one.
    static func separateCopyBundleIdentifier(for profile: ImportedProfileSummary) -> String {
        if profile.appIdentifier.hasSuffix("*") {
            return "\(StoreApp.altstoreAppID).\(profile.teamIdentifier)"
        }
        return profile.appIdentifier
    }

    /// An installed app that already uses `bundleIdentifier`, which a new install would replace.
    static func occupant(of bundleIdentifier: String) async -> String? {
        let context = DatabaseManager.shared.viewContext
        return await context.perform {
            (try? context.fetch(InstalledApp.fetchRequest()))?
                .first { $0.resignedBundleIdentifier == bundleIdentifier }?.name
        }
    }

    /// Packages the running SideKick under a new bundle ID, ready to install as a second copy.
    /// iOS refuses to replace an app with one signed by a different team, so a cross-team
    /// SideKick has to be a separate app. Needs device testing.
    static func prepareSeparateCopy(newID: String, store: IPAImportStore) async throws -> ImportedIPA {
        let currentID = Bundle.main.bundleIdentifier ?? StoreApp.altstoreAppID
        guard newID != currentID else { throw SideKickTransferError.sameInstallation }
        let source = Bundle.main.bundleURL
        let packaging = Task.detached(priority: .userInitiated) { () throws -> (URL, URL) in
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SideKickCopy-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let copy = temporary.appendingPathComponent("App.app")
            try FileManager.default.copyItem(at: source, to: copy)
            try Self.rewriteBundleIdentifiers(in: copy, from: currentID, to: newID)
            return (temporary, try FileManager.default.zipAppBundle(at: copy, compressionLevel: .none))
        }
        let (temporary, ipaURL) = try await packaging.value
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try await store.importManagedIPA(from: ipaURL, expectedBundleIdentifiers: [newID], queuedForUpdate: false)
    }

    // MARK: Export

    /// Writes a "SideKick Transfer" folder inside `parent`, which the user picked in Files.
    static func export(to parent: URL, ipaStore: IPAImportStore, certificatePassword: String? = nil,
                       progress: @escaping @MainActor (String) -> Void = { _ in }) async throws -> URL {
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let stamp = formatter.string(from: .now)
        let folder = parent.appendingPathComponent("SideKick Transfer \(stamp)", isDirectory: true)
        let ipas = folder.appendingPathComponent("IPAs", isDirectory: true)
        let libraryFolder = folder.appendingPathComponent("Library", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: ipas, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
        } catch {
            throw SideKickTransferError.folderUnavailable
        }

        let configurations = (try? await GitHubUpdateConfigurationStore.shared.all()) ?? []
        let selfID = Bundle.main.bundleIdentifier ?? ""
        let installed = try await installedRecords()

        var apps: [SideKickTransferManifest.App] = []
        for record in installed where record.installedID != selfID && record.originalID != StoreApp.altstoreAppID {
            progress("Packaging \(record.name)")
            var ipaPath: String?
            if FileManager.default.fileExists(atPath: record.fileURL.path) {
                let name = "\(safeName(record.originalID))-\(UUID().uuidString.prefix(8)).ipa"
                do {
                    try await packageInstalledApp(record, to: ipas.appendingPathComponent(name))
                    ipaPath = "IPAs/" + name
                } catch {
                    debugLog("[SideKick] Transfer couldn’t package \(record.installedID): \(error.localizedDescription)")
                }
            }
            var github = configurations.first { $0.id == record.installedID }
            // Tokens live in this copy's Keychain; the new copy signs in to GitHub again.
            github?.tokenID = nil
            github?.pendingSelfUpdate = nil
            apps.append(.init(name: record.name, originalBundleIdentifier: record.originalID,
                installedBundleIdentifier: record.installedID, version: record.version,
                buildVersion: record.buildVersion, ipaPath: ipaPath, github: github))
        }

        progress("Copying imported IPAs")
        var library: [SideKickTransferManifest.LibraryIPA] = []
        for entry in (try? await ipaStore.importedApps()) ?? [] {
            do {
                let source = try await ipaStore.fileURL(for: entry)
                defer { SideKickStorageCleanup.finishTemporaryFile(source) }
                let name = "\(safeName(entry.bundleIdentifier))-\(UUID().uuidString.prefix(8)).ipa"
                try FileManager.default.copyItem(at: source, to: libraryFolder.appendingPathComponent(name))
                var copy = entry
                copy.githubImportConfiguration?.tokenID = nil
                library.append(.init(ipaPath: "Library/" + name, entry: copy))
            } catch {
                debugLog("[SideKick] Transfer skipped imported IPA \(entry.bundleIdentifier): \(error.localizedDescription)")
            }
        }

        let liveContainerSources = configurations.filter { $0.id.hasPrefix("livecontainer:") }.map { value -> GitHubUpdateConfiguration in
            var value = value
            value.tokenID = nil
            return value
        }
        guard !apps.isEmpty || !library.isEmpty || !liveContainerSources.isEmpty else {
            try? FileManager.default.removeItem(at: folder)
            throw SideKickTransferError.nothingToExport
        }

        var settings: [String: SideKickTransferManifest.Setting] = [:]
        for key in settingKeys {
            switch UserDefaults.standard.object(forKey: key) {
            case let value as Bool: settings[key] = .bool(value)
            case let value as String: settings[key] = .string(value)
            default: break
            }
        }

        var manifest = SideKickTransferManifest(exportedAt: .now, sourceBundleIdentifier: selfID, apps: apps,
            library: library, liveContainerSources: liveContainerSources, settings: settings)
        manifest.offloadedApps = try await offloadedAppNames()
        if let certificatePassword, !certificatePassword.isEmpty {
            progress("Protecting certificates")
            manifest.appleCertificates = try SigningAccountStore().transferableCertificates(password: certificatePassword)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent(SideKickTransferManifest.fileName), options: .atomic)
        return folder
    }

    // MARK: Import

    /// Reads a transfer folder. Each app's IPA joins the library with its GitHub source and
    /// installed-build key attached, the same way a repository download is queued. Installing
    /// it records that build, so SideKick doesn't download it again.
    /// Whether a transfer folder carries Apple certificates, so the UI can ask for the password first.
    static func transferHasCertificates(_ folder: URL) -> Bool {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(SideKickTransferManifest.fileName)) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return !((try? decoder.decode(SideKickTransferManifest.self, from: data))?.appleCertificates ?? []).isEmpty
    }

    static func importTransfer(from folder: URL, ipaStore: IPAImportStore, certificatePassword: String? = nil,
                               progress: @escaping @MainActor (String) -> Void = { _ in }) async throws -> SideKickTransferImportResult {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let manifestURL = folder.appendingPathComponent(SideKickTransferManifest.fileName)
        guard let data = try? Data(contentsOf: manifestURL) else { throw SideKickTransferError.notATransferFolder }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SideKickTransferManifest.self, from: data)
        guard manifest.format <= SideKickTransferManifest.currentFormat else { throw SideKickTransferError.unsupportedFormat }
        guard manifest.sourceBundleIdentifier != Bundle.main.bundleIdentifier else { throw SideKickTransferError.sameInstallation }

        var result = SideKickTransferImportResult(importedApps: [], importedLibraryIPAs: 0, restoredSources: 0,
            skipped: [], sourceBundleIdentifier: manifest.sourceBundleIdentifier)
        result.offloadedApps = manifest.offloadedApps ?? []
        result.appsWithoutData = manifest.apps.filter { !$0.keepsDataWhenReinstalled }.map(\.name)

        // Check the certificate password before changing anything else.
        if let certificates = manifest.appleCertificates, !certificates.isEmpty {
            if let certificatePassword, !certificatePassword.isEmpty {
                do {
                    result.restoredCertificates = try SigningAccountStore.storeTransferredCertificates(certificates, password: certificatePassword)
                } catch {
                    throw SideKickTransferError.wrongCertificatePassword
                }
            } else {
                result.certificatesNeedPassword = true
            }
        }

        // Library first: an installed app's own build below replaces a library copy of the same app.
        for item in manifest.library {
            progress("Importing \(item.entry.name)")
            guard let url = resolve(item.ipaPath, in: folder) else { result.skipped.append(item.entry.name); continue }
            do {
                _ = try await ipaStore.importManagedIPA(from: url, expectedBundleIdentifiers: [item.entry.bundleIdentifier],
                    updateKey: item.entry.githubUpdateKey, repositoryURL: item.entry.githubRepositoryURL, targetID: nil,
                    sourceIdentity: item.entry.githubSourceIdentity, importConfiguration: item.entry.githubImportConfiguration,
                    queuedForUpdate: false)
                result.importedLibraryIPAs += 1
            } catch {
                result.skipped.append("\(item.entry.name): \(error.localizedDescription)")
            }
        }

        for app in manifest.apps {
            progress("Importing \(app.name)")
            guard let path = app.ipaPath, let url = resolve(path, in: folder) else {
                result.skipped.append("\(app.name): its signed copy wasn’t available to export")
                continue
            }
            var origin = app.github
            origin?.bundleIdentifier = app.originalBundleIdentifier
            origin?.originalBundleIdentifier = app.originalBundleIdentifier
            let key = origin?.installedBuild?.key ?? origin?.effectiveBaselineKey
            do {
                _ = try await ipaStore.importManagedIPA(from: url, expectedBundleIdentifiers: [app.originalBundleIdentifier],
                    updateKey: key, repositoryURL: origin?.repositoryURL, targetID: nil,
                    sourceIdentity: origin?.sourceIdentity, importConfiguration: origin, queuedForUpdate: false)
                result.importedApps.append(app.name)
            } catch {
                result.skipped.append("\(app.name): \(error.localizedDescription)")
            }
        }

        let existing = Set(((try? await GitHubUpdateConfigurationStore.shared.all()) ?? []).map(\.id))
        for source in manifest.liveContainerSources where !existing.contains(source.id) {
            do {
                try await GitHubUpdateConfigurationStore.shared.save(source)
                result.restoredSources += 1
            } catch {
                result.skipped.append("LiveContainer source \(source.id): \(error.localizedDescription)")
            }
        }

        for (key, value) in manifest.settings where settingKeys.contains(key) {
            switch value {
            case .bool(let flag): UserDefaults.standard.set(flag, forKey: key)
            case .string(let text): UserDefaults.standard.set(text, forKey: key)
            }
        }
        NotificationCenter.default.post(name: .sideKickImportedIPAsDidChange, object: nil)
        return result
    }

    // MARK: Helpers

    private struct InstalledRecord: Sendable {
        let name: String
        let originalID: String
        let installedID: String
        let version: String
        let buildVersion: String
        let fileURL: URL
    }

    private static func offloadedAppNames() async throws -> [String] {
        let context = DatabaseManager.shared.viewContext
        return try await context.perform {
            try context.fetch(InstalledApp.fetchRequest())
                .filter { !$0.isActive && UserDefaults.standard.string(forKey: "SideKick.offload." + $0.resignedBundleIdentifier) == "offloaded" }
                .map(\.name)
        }
    }

    private static func installedRecords() async throws -> [InstalledRecord] {
        let context = DatabaseManager.shared.viewContext
        return try await context.perform {
            try context.fetch(InstalledApp.fetchRequest()).filter(\.isActive).map {
                InstalledRecord(name: $0.name, originalID: $0.bundleIdentifier, installedID: $0.resignedBundleIdentifier,
                    version: $0.version, buildVersion: $0.buildVersion, fileURL: $0.fileURL)
            }
        }
    }

    /// Zips the cached signed bundle with the app's own bundle ID restored. The executable is
    /// untouched, so its Mach-O identity still matches the GitHub receipt after re-signing.
    private static func packageInstalledApp(_ record: InstalledRecord, to destination: URL) async throws {
        let packaging = Task.detached(priority: .userInitiated) {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SideKickTransfer-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let copy = temporary.appendingPathComponent("App.app")
            try FileManager.default.copyItem(at: record.fileURL, to: copy)
            if record.installedID != record.originalID {
                try Self.rewriteBundleIdentifiers(in: copy, from: record.installedID, to: record.originalID)
            }
            let ipa = try FileManager.default.zipAppBundle(at: copy, compressionLevel: .none)
            try FileManager.default.moveItem(at: ipa, to: destination)
        }
        try await packaging.value
    }

    /// Replaces the bundle ID prefix in the app and its extensions' Info.plist files.
    nonisolated static func rewriteBundleIdentifiers(in appURL: URL, from oldID: String, to newID: String) throws {
        var bundles = [appURL]
        let plugins = appURL.appendingPathComponent("PlugIns", isDirectory: true)
        if let extensions = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) {
            bundles += extensions.filter { $0.pathExtension == "appex" }
        }
        for bundle in bundles {
            let plistURL = bundle.appendingPathComponent("Info.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let identifier = plist["CFBundleIdentifier"] as? String else { continue }
            if let rewritten = SideKickTransferIdentifiers.rewrite(identifier, from: oldID, to: newID) {
                plist["CFBundleIdentifier"] = rewritten
                let output = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
                try output.write(to: plistURL, options: .atomic)
            }
        }
    }

    private static func resolve(_ relativePath: String, in folder: URL) -> URL? {
        guard !relativePath.contains(".."), !relativePath.hasPrefix("/") else { return nil }
        let url = folder.appendingPathComponent(relativePath)
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    private static func safeName(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" })
    }
}
