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

    /// Hides only the saved row; never uninstalls an app or deletes its recovery data.
    func forgetSavedApp() async throws {
        guard !Self.running, !AppManager.shared.isActivelyManagingAnyApp else { throw AppOffloadError.inUse }
        Self.running = true
        defer { Self.running = false }
        let installed = try await installedRecord()
        guard !installed.isActive else { throw AppOffloadError.unsupported }
        UserDefaults.standard.set(true, forKey: "SideKick.hidden-offloaded." + app.id)
    }

    func perform(restoring: Bool,
                 stageHandler: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                 progressHandler: @escaping @MainActor @Sendable (Double) -> Void = { _ in }) async throws {
        guard !Self.running, !AppManager.shared.isActivelyManagingAnyApp else { throw AppOffloadError.inUse }
        Self.running = true
        defer { Self.running = false }
        stageHandler("Checking the retained app and backup state")
        let installed = try await installedRecord()
        guard let presenter = UIApplication.shared.topViewController() else { throw AppOffloadError.inUse }
        guard ALTApplication(fileURL: installed.fileURL) != nil else { throw AppOffloadError.sourceMissing }
        if !restoring {
            guard installed.isActive, !Self.blocksNativeOperations(app.id) else { throw AppOffloadError.restoreRequired }
        }
        let appID = installed.bundleIdentifier
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name("SideKick.pipelineStep"), object: nil, queue: .main) { notification in
            guard notification.userInfo?["appID"] as? String == appID,
                  let step = notification.userInfo?["step"] as? String,
                  let message = Self.stageMessage(step) else { return }
            Task { @MainActor in stageHandler(message) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try SideKickStorageCleanup.beginOperation()
        defer { SideKickStorageCleanup.endOperation() }
        // Use SideStore's normal backup/restore pipeline, including its App Group.
        let legacy = UserDefaults.standard.isLegacyDeactivationSupported
        UserDefaults.standard.isLegacyDeactivationSupported = false
        defer { UserDefaults.standard.isLegacyDeactivationSupported = legacy }
        let key = "SideKick.offload." + app.id
        let backup = FileManager.default.backupDirectoryURL(for: installed)
        let hasBackup = backup.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        // An interrupted uninstall can leave Core Data marked active even after
        // device removal. Restore its completed backup instead of a blank binary.
        let binaryRecoveryKey = "SideKick.binary-recovery." + app.id
        let knownOffload = Self.blocksNativeOperations(app.id) && !UserDefaults.standard.bool(forKey: binaryRecoveryKey)
        // A failed install can leave only a false inactive flag. Reinstall that
        // retained binary directly; a real offload must keep its backup intact.
        let recoverBinary = restoring && !hasBackup && !knownOffload
        if restoring && knownOffload && !hasBackup { throw AppOffloadError.backupUnavailable }
        if !recoverBinary {
            guard let group = Bundle.main.altstoreAppGroup,
                  FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil else {
                throw AppOffloadError.backupUnavailable
            }
        }
        if restoring {
            let assigned = try ImportedCertificateStore.shared.assignedSigningCertificate(
                accountIdentifier: app.accountIdentifier, teamIdentifier: app.teamIdentifier)
            try SigningIdentityPolicy.validateResign(
                installedTeam: SideStoreOperationService.installedSigningTeam(installed),
                targetTeam: assigned?.record.profile?.teamIdentifier ?? app.teamIdentifier)
            if let profile = assigned?.record.profile {
                try SigningIdentityPolicy.validateProfile(profile.appIdentifier, for: installed.resignedBundleIdentifier)
            }
        }
        stageHandler("Connecting to this iPhone")
        let lease = try await LocalVPNService.shared.acquire()
        defer { LocalVPNService.shared.release(lease) }
        UserDefaults.standard.set(recoverBinary, forKey: binaryRecoveryKey)
        UserDefaults.standard.set(restoring ? "restoring" : "offloading", forKey: key)
        do {
            stageHandler("Preparing the signing account")
            try await accounts.withAccount(accountIdentifier: app.accountIdentifier, teamIdentifier: app.teamIdentifier) {
                try ImportedCertificateStore.shared.prepareProfileAssignment(
                    bundleIdentifiers: [installed.bundleIdentifier, installed.resignedBundleIdentifier],
                    accountIdentifier: app.accountIdentifier, teamIdentifier: app.teamIdentifier)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let observationBox = ProgressObservationBox()
                    let finished: (Result<InstalledApp, Error>) -> Void = {
                        observationBox.finish()
                        continuation.resume(with: $0.map { _ in () })
                    }
                    let group: RefreshGroup
                    if recoverBinary {
                        group = AppManager.shared.reinstall(installed, presentingViewController: presenter, completionHandler: finished)
                    } else if restoring {
                        if installed.isActive {
                            group = AppManager.shared.restore(installed, presentingViewController: presenter, completionHandler: finished)
                        } else {
                            group = AppManager.shared.activate(installed, presentingViewController: presenter, completionHandler: finished)
                        }
                    } else {
                        group = AppManager.shared.deactivate(installed, presentingViewController: presenter, completionHandler: finished)
                    }
                    let observation = group.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                        let value = progress.fractionCompleted
                        Task { @MainActor in progressHandler(value) }
                    }
                    observationBox.retain(observation)
                }
            }
            UserDefaults.standard.set(restoring ? "active" : "offloaded", forKey: key)
            UserDefaults.standard.removeObject(forKey: binaryRecoveryKey)
            if restoring { UserDefaults.standard.removeObject(forKey: "SideKick.transfer." + app.id) }
            await ExpirationNotificationScheduler.update()
        } catch {
            UserDefaults.standard.set("recoveryNeeded", forKey: key)
            throw error
        }
    }

    private nonisolated static func stageMessage(_ step: String) -> String? {
        switch step {
        case "stageBackupApp": "Preparing the SideKick backup helper"
        case "updateAppCertificate", "verifyCertificate": "Checking the signing certificate"
        case "fetchProvisioningProfiles": "Preparing signing permissions and shared backup storage"
        case "resignApp": "Signing the app"
        case "createIPA", "exportResignedIPA": "Preparing the signed IPA"
        case "sendApp", "installApp": "Installing the prepared app on this iPhone"
        case "backupAppData": "Open the app when prompted. The SideKick helper is backing up its data."
        case "restoreAppData": "Open the app when prompted. The SideKick helper is restoring its data."
        case "uninstallApp": "Backup finished. Removing the native installation"
        case "markAppInactive": "Saving the offloaded app’s status"
        case "stageApp": "Preparing the original app for reinstallation"
        case "removeBackupData": "Restore finished. Cleaning up the completed backup"
        case "cacheResignedMetadata", "cleanStagedApp": "Saving app status and finishing up"
        default: nil
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
    case unsupported, sourceMissing, inUse, restoreRequired, backupUnavailable
    var errorDescription: String? {
        switch self {
        case .unsupported: "SideKick cannot offload itself."
        case .sourceMissing: "The retained app source is unavailable. Import its original IPA before continuing."
        case .inUse: "Another app operation is running. Try again when it finishes."
        case .restoreRequired: "Restore or recover this offloaded app before updating or refreshing it."
        case .backupUnavailable: "SideKick cannot access this app's shared backup storage. Restore SideKick's original signing team and App Group permissions before continuing. The saved app and its backup have not been deleted."
        }
    }
}
