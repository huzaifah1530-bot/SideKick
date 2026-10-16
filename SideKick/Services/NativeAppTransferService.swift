import CoreData
import Foundation
import SideSign
import UIKit

enum NativeTransferAction: Equatable { case export, offload, restore, recover, login }

struct NativeTransferRecord: Codable {
    var state: String = "notStarted"
    var dataBookmark: Data?
    var guestVerified = false
    var loginDestination: AppCredentialDestination?
}

@MainActor
final class NativeAppTransferService {
    private static var running = false
    static var isRunning: Bool { running }
    static func hasUnfinishedTransfer(_ appID: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "SideKick.transfer." + appID),
              let record = try? JSONDecoder().decode(NativeTransferRecord.self, from: data) else { return false }
        return ["offloaded", "exporting", "offloading", "restoring", "recoveryNeeded"].contains(record.state)
    }
    private let app: InstalledAppSummary
    private let accounts: SigningAccountStore

    init(app: InstalledAppSummary, accounts: SigningAccountStore) {
        self.app = app
        self.accounts = accounts
    }

    var record: NativeTransferRecord {
        get {
            guard let data = UserDefaults.standard.data(forKey: "SideKick.transfer." + app.id) else { return NativeTransferRecord() }
            return (try? JSONDecoder().decode(NativeTransferRecord.self, from: data)) ?? NativeTransferRecord()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "SideKick.transfer." + app.id)
            }
        }
    }

    func retainDataFolder(_ url: URL) async throws {
        guard url.startAccessingSecurityScopedResource() else { throw AppDataTransferError.invalidFolder }
        defer { url.stopAccessingSecurityScopedResource() }
        let installed = try await installedRecord()
        let expectedGroups = (ALTApplication(fileURL: installed.fileURL)?.entitlements[.appGroups] as? [String]) ?? []
        let identity = try AppDataTransfer.readIdentity(at: url)
        guard identity.bundleIdentifier == app.id, identity.version == app.version, identity.build == app.buildVersion else {
            throw AppDataTransferError.identityMismatch
        }
        guard Set(identity.appGroupIdentifiers ?? []) == Set(expectedGroups) else { throw AppDataTransferError.appGroupUnavailable }
        var updated = record
        updated.dataBookmark = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        updated.guestVerified = false
        updated.loginDestination = nil
        record = updated
    }

    private func installedRecord() async throws -> InstalledApp {
        guard app.id != Bundle.Info.activeBundleIdentifier,
              !app.bundleIdentifier.lowercased().contains("livecontainer") else {
            throw NativeTransferError.unsupported
        }
        let context = DatabaseManager.shared.viewContext
        guard let installed = try await context.perform({
            try context.fetch(InstalledApp.fetchRequest()).first { $0.resignedBundleIdentifier == self.app.id }
        }), let bundle = ALTApplication(fileURL: installed.fileURL) else { throw NativeTransferError.sourceMissing }
        let groups = bundle.entitlements[.appGroups] as? [String] ?? []
        guard groups.count <= 64, groups.allSatisfy(AppDataTransfer.validGroupIdentifier) else {
            throw AppDataTransferError.appGroupUnavailable
        }
        guard bundle.version == app.version, bundle.buildVersion == app.buildVersion else {
            throw AppDataTransferError.identityMismatch
        }
        return installed
    }

    func prepareGuestIPA() async throws -> URL {
        guard !Self.running else { throw NativeTransferError.inUse }
        Self.running = true
        defer { Self.running = false }
        try SideKickStorageCleanup.beginOperation()
        defer { SideKickStorageCleanup.endOperation() }
        let installed = try await installedRecord()
        let sourceURL = installed.fileURL
        let identity = app.id
        let packaging = Task.detached(priority: .userInitiated) {
            try Self.packageGuestIPA(sourceURL: sourceURL, identity: identity)
        }
        return try await withTaskCancellationHandler {
            try await packaging.value
        } onCancel: {
            packaging.cancel()
        }
    }

    private func credentialRequest() async throws -> [String: Any] {
        guard let bookmark = record.dataBookmark else { throw AppCredentialTransferError.configuration }
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        guard !stale, folder.startAccessingSecurityScopedResource() else { throw AppCredentialTransferError.configuration }
        defer { folder.stopAccessingSecurityScopedResource() }
        let identity = try AppDataTransfer.readIdentity(at: folder)
        guard identity.bundleIdentifier == app.id, identity.version == app.version, identity.build == app.buildVersion else {
            throw AppDataTransferError.identityMismatch
        }
        let destination = try AppCredentialDestination.read(folder: folder, appID: app.id, team: app.teamIdentifier)
        let state = try await LiveContainerStore.shared.snapshot()
        var matchingSchemes: [String] = []
        for connection in state.connections where connection.storageKind != .snapshot && connection.error == nil {
            guard let access = connection.bookmark else { continue }
            var stale = false
            let applications = try URL(resolvingBookmarkData: access, bookmarkDataIsStale: &stale)
            guard !stale, applications.startAccessingSecurityScopedResource() else { continue }
            defer { applications.stopAccessingSecurityScopedResource() }
            for guest in state.apps where guest.connectionID == connection.id && guest.bundleIdentifier == app.id && guest.isAvailable {
                let bundle = applications.appendingPathComponent(guest.folder)
                try OwnedStoragePath.validate(bundle, inside: applications)
                let info = try AppCredentialDestination.metadata(bundle.appendingPathComponent("LCAppInfo.plist"))
                guard info["LCDataUUID"] as? String == destination.container,
                      let containers = info["LCContainers"] as? [[String: Any]],
                      let selected = containers.first(where: { $0["folderName"] as? String == destination.container }),
                      let data = selected["bookmarkData"] as? Data else { continue }
                var obsolete = false
                let selectedFolder = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &obsolete)
                guard !obsolete, selectedFolder.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath() else { continue }
                matchingSchemes.append(connection.scheme)
            }
        }
        guard matchingSchemes.count == 1 else { throw AppCredentialTransferError.configuration }
        let installed = try await installedRecord()
        let context = DatabaseManager.shared.viewContext
        let containers = try await context.perform {
            try context.fetch(InstalledApp.fetchRequest()).filter {
                $0.isActive && $0.bundleIdentifier.lowercased().contains("livecontainer") && $0.team?.identifier == self.app.teamIdentifier
            }
        }
        // Read permissions captured from the signed bundle, never the IPA's original team.
        let native = try signedMetadata(installed)
        var groups = native.entitlements["keychain-access-groups"] as? [String] ?? []
        if groups.isEmpty, let identifier = native.entitlements["application-identifier"] as? String { groups = [identifier] }
        let sourceGroups = Array(Set(groups)).sorted()
        var recipients = 0
        for container in containers {
            guard let signed = try? signedMetadata(container) else { continue }
            let types = signed.info["CFBundleURLTypes"] as? [[String: Any]] ?? []
            let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            if schemes.contains(matchingSchemes[0]),
               (signed.entitlements["keychain-access-groups"] as? [String] ?? []).contains(destination.group) { recipients += 1 }
        }
        guard recipients == 1, !sourceGroups.isEmpty, sourceGroups.count <= 64,
              sourceGroups.allSatisfy({ $0.hasPrefix(app.teamIdentifier + ".") && !$0.contains("*") }),
              !sourceGroups.contains(destination.group) else { throw AppCredentialTransferError.permissions }
        return ["sourceGroups": sourceGroups, "container": destination.container, "group": destination.group, "team": app.teamIdentifier]
    }

    private func signedMetadata(_ installed: InstalledApp) throws -> (entitlements: [String: Any], info: [String: Any]) {
        guard let metadata = try? AppCredentialDestination.metadata(installed.directoryURL.appendingPathComponent("CredentialTransferSigning.plist")),
              metadata["id"] as? String == installed.resignedBundleIdentifier,
              metadata["version"] as? String == installed.version, metadata["build"] as? String == installed.buildVersion,
              let permissions = metadata["entitlements"] as? [String: Any],
              let info = metadata["info"] as? [String: Any] else { throw AppCredentialTransferError.permissions }
        return (permissions, info)
    }

    private nonisolated static func packageGuestIPA(sourceURL: URL, identity: String) throws -> URL {
        try Task.checkCancellation()
        let fm = FileManager.default
        let root = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveContainerTransfers")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let temporary = fm.temporaryDirectory.appendingPathComponent("SideKickGuest-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let copy = temporary.appendingPathComponent("Guest.app")
        try fm.copyItem(at: sourceURL, to: copy)
        guard let bundle = ALTApplication(fileURL: copy) else { throw NativeTransferError.sourceMissing }
        // Keep the native preference-domain identity when LiveContainer launches.
        try bundle.updateInfoPlist(with: ["CFBundleIdentifier": identity])
        try Task.checkCancellation()
        let zipped = try fm.zipAppBundle(at: copy, compressionLevel: .none)
        try Task.checkCancellation()
        let output = root.appendingPathComponent(UUID().uuidString + ".ipa")
        do { try fm.copyItem(at: zipped, to: output) }
        catch { try? fm.removeItem(at: output); throw error }
        try? fm.removeItem(at: zipped)
        return output
    }

    func perform(_ action: NativeTransferAction) async throws {
        guard !Self.running else { throw NativeTransferError.inUse }
        Self.running = true
        defer { Self.running = false }
        let installed = try await installedRecord()
        if action == .export || action == .offload || action == .login {
            guard installed.isActive else { throw NativeTransferError.transferPending }
        }
        guard let presenter = UIApplication.shared.topViewController() else { throw NativeTransferError.inUse }
        let loginRequest = action == .login || action == .offload ? try await credentialRequest() : nil
        if action == .offload {
            guard record.guestVerified, let bookmark = record.dataBookmark,
                  let login = record.loginDestination,
                  login.group == loginRequest?["group"] as? String,
                  login.container == loginRequest?["container"] as? String else { throw NativeTransferError.unverified }
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
            guard !stale else { throw AppDataTransferError.invalidFolder }
            try await retainDataFolder(folder)
            var updated = record; updated.guestVerified = true; updated.loginDestination = login; record = updated
        }
        try SideKickStorageCleanup.beginOperation()
        defer { SideKickStorageCleanup.endOperation() }
        let lease = try await LocalVPNService.shared.acquire()
        defer { LocalVPNService.shared.release(lease) }
        let previous = UserDefaults.standard.object(forKey: "SideKickFileTransferRequest")
        let previousLogin = UserDefaults.standard.object(forKey: "SideKickCredentialTransferRequest")
        if action == .login { UserDefaults.standard.set(loginRequest, forKey: "SideKickCredentialTransferRequest") }
        else { UserDefaults.standard.removeObject(forKey: "SideKickCredentialTransferRequest") }
        let legacy = UserDefaults.standard.isLegacyDeactivationSupported
        UserDefaults.standard.set(action != .recover, forKey: "SideKickFileTransferRequest")
        UserDefaults.standard.isLegacyDeactivationSupported = false
        defer {
            if let previousLogin { UserDefaults.standard.set(previousLogin, forKey: "SideKickCredentialTransferRequest") }
            else { UserDefaults.standard.removeObject(forKey: "SideKickCredentialTransferRequest") }
            if let previous { UserDefaults.standard.set(previous, forKey: "SideKickFileTransferRequest") }
            else { UserDefaults.standard.removeObject(forKey: "SideKickFileTransferRequest") }
            UserDefaults.standard.isLegacyDeactivationSupported = legacy
        }
        var updated = record
        updated.state = action == .restore ? "restoring" : action == .offload ? "offloading" : "exporting"
        record = updated
        do {
            try await accounts.withAccount(accountIdentifier: app.accountIdentifier, teamIdentifier: app.teamIdentifier) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let finished: (Result<InstalledApp, Error>) -> Void = { continuation.resume(with: $0.map { _ in () }) }
                    switch action {
                    case .export, .login: AppManager.shared.backup(installed, presentingViewController: presenter, completionHandler: finished)
                    case .offload: AppManager.shared.deactivate(installed, presentingViewController: presenter, completionHandler: finished)
                    case .restore:
                        if installed.isActive { AppManager.shared.restore(installed, presentingViewController: presenter, completionHandler: finished) }
                        else { AppManager.shared.activate(installed, presentingViewController: presenter, completionHandler: finished) }
                    case .recover: AppManager.shared.reinstall(installed, presentingViewController: presenter, completionHandler: finished)
                    }
                }
            }
            updated = record
            updated.state = action == .offload ? "offloaded" : action == .restore ? "restored" : action == .recover ? "binaryRecovered" : "exported"
            if action != .offload { updated.guestVerified = false }
            if action == .login, let group = loginRequest?["group"] as? String, let container = loginRequest?["container"] as? String {
                updated.loginDestination = AppCredentialDestination(container: container, group: group)
            } else if action != .offload { updated.loginDestination = nil }
            record = updated
            await ExpirationNotificationScheduler.update()
        } catch {
            updated = record
            updated.state = "recoveryNeeded"
            updated.guestVerified = false
            record = updated
            throw error
        }
    }
}

enum NativeTransferError: LocalizedError {
    case unsupported, sourceMissing, inUse, unverified, transferPending
    var errorDescription: String? {
        switch self {
        case .unsupported: "SideKick and LiveContainer cannot be moved using this transfer."
        case .sourceMissing: "The retained app source is unavailable. Import the original IPA before continuing."
        case .inUse: "Another transfer is running or the app cannot present the transfer screen."
        case .unverified: "Select the exported data folder and verify the guest in LiveContainer before freeing the native slot."
        case .transferPending: "This app is offloaded or has an unfinished transfer. Open Move to LiveContainer to restore or recover it first."
        }
    }
}
