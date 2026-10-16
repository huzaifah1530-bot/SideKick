import CoreData
import Foundation
import SideSign
import UIKit

@MainActor
final class AppOffloadService {
    private static var running = false
    static var isRunning: Bool { running }

    static func blocksNativeOperations(_ id: String) -> Bool {
        let state = UserDefaults.standard.string(forKey: "SideKick.offload." + id)
        if ["offloading", "offloaded", "restoring", "recoveryNeeded"].contains(state ?? "") { return true }
        return needsLegacyRecovery(id)
    }

    static func needsLegacyRecovery(_ id: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "SideKick.transfer." + id),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = record["state"] as? String else { return false }
        return ["offloaded", "exporting", "offloading", "restoring", "recoveryNeeded"].contains(state)
    }

    private let app: InstalledAppSummary
    private let accounts: SigningAccountStore
    init(app: InstalledAppSummary, accounts: SigningAccountStore) { self.app = app; self.accounts = accounts }

    private func installedRecord() async throws -> InstalledApp {
        guard app.id != Bundle.Info.activeBundleIdentifier else { throw AppOffloadError.unsupported }
        let context = DatabaseManager.shared.viewContext
        guard let installed = try await context.perform({
            try context.fetch(InstalledApp.fetchRequest()).first { $0.resignedBundleIdentifier == self.app.id }
        }) else { throw AppOffloadError.sourceMissing }
        return installed
    }

    func isOffloaded() async throws -> Bool { !(try await installedRecord()).isActive }

    func perform(restoring: Bool) async throws {
        guard !Self.running, !AppManager.shared.isActivelyManagingAnyApp else { throw AppOffloadError.inUse }
        Self.running = true
        defer { Self.running = false }
        let installed = try await installedRecord()
        guard let presenter = UIApplication.shared.topViewController() else { throw AppOffloadError.inUse }
        guard ALTApplication(fileURL: installed.fileURL) != nil else { throw AppOffloadError.sourceMissing }
        if !restoring {
            guard installed.isActive, !Self.blocksNativeOperations(app.id) else { throw AppOffloadError.restoreRequired }
        }
        try SideKickStorageCleanup.beginOperation()
        defer { SideKickStorageCleanup.endOperation() }
        let lease = try await LocalVPNService.shared.acquire()
        defer { LocalVPNService.shared.release(lease) }
        // Use SideStore's normal backup/restore pipeline, including its App Group.
        let legacy = UserDefaults.standard.isLegacyDeactivationSupported
        UserDefaults.standard.isLegacyDeactivationSupported = false
        defer { UserDefaults.standard.isLegacyDeactivationSupported = legacy }
        let key = "SideKick.offload." + app.id
        let backup = FileManager.default.backupDirectoryURL(for: installed)
        let hasBackup = backup.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        // An interrupted uninstall can leave Core Data marked active even after
        // device removal. Restore its completed backup instead of a blank binary.
        let recoverBinary = restoring && (Self.needsLegacyRecovery(app.id) || (installed.isActive && !hasBackup))
        UserDefaults.standard.set(restoring ? "restoring" : "offloading", forKey: key)
        do {
            try await accounts.withAccount(accountIdentifier: app.accountIdentifier, teamIdentifier: app.teamIdentifier) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let finished: (Result<InstalledApp, Error>) -> Void = { continuation.resume(with: $0.map { _ in () }) }
                    if recoverBinary {
                        AppManager.shared.reinstall(installed, presentingViewController: presenter, completionHandler: finished)
                    } else if restoring {
                        if installed.isActive {
                            AppManager.shared.restore(installed, presentingViewController: presenter, completionHandler: finished)
                        } else {
                            AppManager.shared.activate(installed, presentingViewController: presenter, completionHandler: finished)
                        }
                    } else {
                        AppManager.shared.deactivate(installed, presentingViewController: presenter, completionHandler: finished)
                    }
                }
            }
            UserDefaults.standard.set(restoring ? "active" : "offloaded", forKey: key)
            if restoring { UserDefaults.standard.removeObject(forKey: "SideKick.transfer." + app.id) }
            await ExpirationNotificationScheduler.update()
        } catch {
            UserDefaults.standard.set("recoveryNeeded", forKey: key)
            throw error
        }
    }

    func prepareIPA(store: IPAImportStore) async throws -> ImportedIPA {
        guard !Self.running, !AppManager.shared.isActivelyManagingAnyApp else { throw AppOffloadError.inUse }
        Self.running = true
        defer { Self.running = false }
        let installed = try await installedRecord()
        guard !installed.isActive, UserDefaults.standard.string(forKey: "SideKick.offload." + app.id) == "offloaded",
              let bundle = ALTApplication(fileURL: installed.fileURL) else { throw AppOffloadError.restoreRequired }
        try SideKickStorageCleanup.beginOperation()
        defer { SideKickStorageCleanup.endOperation() }
        let source = installed.fileURL
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SideKickOffloadIPA-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let packaging = Task.detached(priority: .userInitiated) {
            let copy = temporary.appendingPathComponent("App.app")
            try FileManager.default.copyItem(at: source, to: copy)
            return try FileManager.default.zipAppBundle(at: copy, compressionLevel: .none)
        }
        let url = try await packaging.value
        let configuration = try await GitHubUpdateConfigurationStore.shared.configuration(for: app.id)
        // Keep the update source, but do not invent an exact installed-build receipt.
        return try await store.importManagedIPA(from: url, expectedBundleIdentifiers: [bundle.bundleIdentifier],
            repositoryURL: configuration?.repositoryURL, sourceIdentity: configuration?.sourceIdentity,
            importConfiguration: configuration, queuedForUpdate: false)
    }
}

enum AppOffloadError: LocalizedError {
    case unsupported, sourceMissing, inUse, restoreRequired
    var errorDescription: String? {
        switch self {
        case .unsupported: "SideKick cannot offload itself."
        case .sourceMissing: "The retained app source is unavailable. Import its original IPA before continuing."
        case .inUse: "Another app operation is running. Try again when it finishes."
        case .restoreRequired: "Restore or recover this offloaded app before updating or refreshing it."
        }
    }
}
