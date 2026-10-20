import CoreData
import Foundation
import SideSign
import UIKit

@MainActor
final class SideStoreOperationService {
    private let accountStore: SigningAccountStore
    private let ipaStore: IPAImportStore

    init(accountStore: SigningAccountStore, ipaStore: IPAImportStore) {
        self.accountStore = accountStore
        self.ipaStore = ipaStore
    }

    func installedApps() async -> [InstalledAppSummary] {
        do { return try await loadInstalledApps() }
        catch {
            debugLog("[SideKick] Couldn’t load installed apps: \(error.localizedDescription)")
            return []
        }
    }

    func loadInstalledApps(loadIcons: Bool = true) async throws -> [InstalledAppSummary] {
        let context = DatabaseManager.shared.viewContext
        let records = try await context.perform {
            let selfTeamIdentifier = ALTApplication(fileURL: Bundle.Info.activeBundleURL)?
                .provisioningProfile?.teamIdentifier
            let apps = try context.fetch(InstalledApp.fetchRequest())
            let selfApp = InstalledApp.fetchAltStore(in: context)
            let candidates = apps.contains(where: { $0.bundleIdentifier == StoreApp.altstoreAppID })
                ? apps
                : apps + (selfApp.map { [$0] } ?? [])

            if let selfApp, selfApp.team == nil,
               let teamIdentifier = selfTeamIdentifier,
               let ownerTeam = (try? context.fetch(Team.fetchRequest()))?.first(where: { $0.identifier == teamIdentifier }) {
                selfApp.team = ownerTeam
                try? context.save()
            }

            // Keep an installed record visible even if its saved account needs
            // reconnecting after a certificate/session change.
            return candidates.map { app -> (InstalledApp, String, String, String, String, String, String, String, String, Date, String?, String?, String?) in
                let team = app.team
                let account = team?.account
                let runningBundle = app.bundleIdentifier == StoreApp.altstoreAppID ? Bundle(url: Bundle.Info.activeBundleURL) : nil
                let runningIdentity = runningBundle?.executableURL.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }.flatMap { GitHubExecutableIdentity.read($0) }
                return (
                    app,
                    app.bundleIdentifier,
                    app.resignedBundleIdentifier,
                    app.name,
                    runningBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? app.version,
                    runningBundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? app.buildVersion,
                    account?.appleID ?? "Sign in required",
                    account?.identifier ?? "",
                    team?.identifier ?? app.customProvisioningProfile?.teamIdentifier ?? "",
                    app.expirationDate,
                    runningBundle != nil ? runningIdentity : Bundle(url: app.fileURL)?.executableURL
                        .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
                        .flatMap { GitHubExecutableIdentity.read($0) },
                    runningBundle != nil ? runningIdentity : app.appBundleFingerprint,
                    // SideStore records the serial only when an override certificate signed the app.
                    runningBundle != nil
                        ? Bundle.main.object(forInfoDictionaryKey: Bundle.Info.certificateID) as? String
                        : app.certificateSerialNumber
                )
            }
        }

        var summaries: [InstalledAppSummary] = []
        for record in records {
            let iconData: Data?
            if loadIcons, record.1 == StoreApp.altstoreAppID {
                // SideKick's own row: app icon sets can't be loaded by name, so use the
                // bundled preview of whichever icon is active (vendor loadIcon returns nil).
                iconData = AppIconController.currentIconData()
            } else if loadIcons { iconData = try? await record.0.loadIcon()?.pngData() }
            else { iconData = nil }
            summaries.append(InstalledAppSummary(
                bundleIdentifier: record.1,
                resignedBundleIdentifier: record.2,
                name: record.3,
                version: record.4,
                buildVersion: record.5,
                accountEmail: record.6,
                accountIdentifier: record.7,
                teamIdentifier: record.8,
                iconData: iconData,
                expirationDate: record.9,
                contentFingerprint: record.11,
                executableIdentity: record.10,
                isActive: record.0.isActive,
                signingCertificateSerial: record.12
            ))
        }
        let identities = Dictionary(grouping: summaries, by: \.bundleIdentifier).mapValues { $0.map(\.id) }
        try? await GitHubUpdateConfigurationStore.shared.migrateInstalledIdentifiers(identities)
        try? await GitHubUpdateConfigurationStore.shared.migrateInstalledObservations(summaries.map(\.updateTarget))
        try? await ipaStore.migrateQueuedInstallations(identities)
        if let bundle = Bundle(url: Bundle.Info.activeBundleURL), let binaryURL = bundle.executableURL,
           let binary = try? Data(contentsOf: binaryURL), let identity = GitHubExecutableIdentity.read(binary),
           let target = summaries.first(where: { $0.id == bundle.bundleIdentifier })?.updateTarget {
            _ = try? await GitHubUpdateConfigurationStore.shared.recoverSelfUpdate(for: target, executableIdentity: identity)
            if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                do {
                    try await ipaStore.removeInstalledSelfUpdates(targetID: target.id, version: version,
                        build: build, executableIdentity: identity)
                } catch {
                    // A failed index save keeps the queue intact for the next catalogue load.
                    debugLog("[SideKick] Could not clear the completed self-update queue: \(error.localizedDescription)")
                }
            }
        }
        return summaries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func install(
        _ ipa: ImportedIPA,
        using account: SigningAccountSummary,
        recoveryHandler: @escaping @MainActor @Sendable () -> Void = {},
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
        try await SideKickDiagnostics.perform(.install, stage: .installation) {
            try await performInstall(ipa, using: account, recoveryHandler: recoveryHandler, progressHandler: progressHandler)
        }
    }

    private func performInstall(
        _ ipa: ImportedIPA,
        using account: SigningAccountSummary,
        recoveryHandler: @escaping @MainActor @Sendable () -> Void = {},
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard !AppOffloadService.isRunning else { throw AppOffloadError.inUse }
        if let target = ipa.queuedForInstalledAppID, AppOffloadService.blocksNativeOperations(target) {
            throw AppOffloadError.restoreRequired
        }
        guard let presenter = UIApplication.shared.topViewController() else {
            throw SideStoreOperationError.presentationUnavailable
        }
        try SideKickStorageCleanup.beginOperation()
        defer { SideKickStorageCleanup.endOperation() }
        let url = try await ipaStore.fileURL(for: ipa)
        defer { SideKickStorageCleanup.finishTemporaryFile(url) }
        let vpnLease = try await LocalVPNService.shared.acquire()
        defer { LocalVPNService.shared.release(vpnLease) }
        let runningBundle = Bundle(url: Bundle.Info.activeBundleURL)
        let selfTargetID = ipa.queuedForInstalledAppID == runningBundle?.bundleIdentifier ? ipa.queuedForInstalledAppID : nil
        if let targetID = selfTargetID, let key = ipa.githubUpdateKey,
           let source = ipa.githubSourceIdentity, let identity = ipa.executableIdentity,
           ALTApplication(fileURL: Bundle.Info.activeBundleURL)?.provisioningProfile?.teamIdentifier == account.teamIdentifier {
            try await GitHubUpdateConfigurationStore.shared.prepareSelfUpdate(key: key, targetID: targetID,
                expectedSource: source, executableIdentity: identity)
        }
        let installedID: String
        do {
            let useImportedCertificate = try await importedCertificateUse(forUpdateOf: ipa.queuedForInstalledAppID, using: account)
            if useImportedCertificate {
                try await ensureImportedProfileIsFree(for: ipa, using: account)
            }
            installedID = try await retryAfterClearingRevokedAssignedProfile(
                for: ipa.bundleIdentifier,
                recoveryHandler: recoveryHandler
            ) {
                try await accountStore.withAccount(
                    accountIdentifier: account.accountIdentifier,
                    teamIdentifier: account.teamIdentifier,
                    useImportedCertificate: useImportedCertificate
                ) {
                    try ImportedCertificateStore.shared.prepareProfileAssignment(
                        bundleIdentifiers: [ipa.bundleIdentifier] + [ipa.queuedForInstalledAppID].compactMap { $0 },
                        accountIdentifier: account.accountIdentifier,
                        teamIdentifier: account.teamIdentifier,
                        useImportedCertificate: useImportedCertificate
                    )
                    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                        guard !SideKickStorageCleanup.isRemovingFiles else {
                            continuation.resume(throwing: StorageCleanupError.operationRunning)
                            return
                        }
                        let observationBox = ProgressObservationBox()
                        let group = AppManager.shared.install(.url(url), presentingViewController: presenter) { result in
                            observationBox.finish()
                            switch result {
                            case .failure(let error): continuation.resume(throwing: error)
                            case .success(let app):
                                guard let context = app.managedObjectContext else {
                                    continuation.resume(throwing: SideStoreOperationError.installedAppUnavailable)
                                    return
                                }
                                context.perform { continuation.resume(returning: app.resignedBundleIdentifier) }
                            }
                        }
                        let observation = group.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                            let fraction = progress.fractionCompleted
                            Task { @MainActor in progressHandler(fraction) }
                        }
                        observationBox.retain(observation)
                    }
                }
            }
        } catch {
            if let targetID = selfTargetID, let key = ipa.githubUpdateKey {
                try? await GitHubUpdateConfigurationStore.shared.cancelSelfUpdate(targetID: targetID, key: key)
            }
            throw error
        }
        // A self-install callback can arrive in the old process before replacement.
        // Leave the pending receipt for the new binary to confirm on its next launch.
        let selfBinaryMatches = selfTargetID == nil || (ipa.executableIdentity != nil &&
            runningBundle?.executableURL.flatMap { try? Data(contentsOf: $0) }.flatMap { GitHubExecutableIdentity.read($0) } == ipa.executableIdentity)
        if selfBinaryMatches, let target = await installedApps().first(where: { $0.id == installedID })?.updateTarget,
           let key = ipa.githubUpdateKey ?? ipa.githubImportConfiguration?.effectiveBaselineKey {
            let store = GitHubUpdateConfigurationStore.shared
            do {
                if let origin = ipa.githubImportConfiguration {
                    _ = try await store.recordSuccessfulImport(origin, key: key, for: target)
                } else if let expectedSource = ipa.githubSourceIdentity, ipa.queuedForInstalledAppID == target.id {
                    _ = try await store.recordInstalled(key: key, for: target, expectedSource: expectedSource)
                }
            } catch {
                // Installation already succeeded. Keep any pending self-update
                // receipt for next-launch recovery and report persistence separately.
                debugLog("[SideKick] Installation succeeded, but its GitHub update receipt could not be saved: \(error.localizedDescription)")
            }
        }
        if selfBinaryMatches, ipa.queuedForInstalledAppID != nil {
            do { try await ipaStore.delete(ipa) }
            catch {
                // The app is installed. Cleanup failure must not report installation failure.
                debugLog("[SideKick] Installation succeeded, but queued IPA cleanup failed: \(error.localizedDescription)")
            }
        }
        await ExpirationNotificationScheduler.update()
    }

    func refresh(
        bundleIdentifier: String,
        requiresPresenter: Bool = true,
        updatesExpiryNotifications: Bool = true,
        using selectedAccount: SigningAccountSummary? = nil,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
        try await SideKickDiagnostics.perform(.refresh, stage: .refresh) {
            try await performRefresh(bundleIdentifier: bundleIdentifier, requiresPresenter: requiresPresenter, updatesExpiryNotifications: updatesExpiryNotifications, using: selectedAccount, progressHandler: progressHandler)
        }
    }

    private func performRefresh(
        bundleIdentifier: String,
        requiresPresenter: Bool = true,
        updatesExpiryNotifications: Bool = true,
        using selectedAccount: SigningAccountSummary? = nil,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let presenter = UIApplication.shared.topViewController()
        guard !AppOffloadService.isRunning else { throw AppOffloadError.inUse }
        guard !AppOffloadService.blocksNativeOperations(bundleIdentifier) else { throw AppOffloadError.restoreRequired }
        guard !requiresPresenter || presenter != nil else {
            throw SideStoreOperationError.presentationUnavailable
        }
        let context = DatabaseManager.shared.viewContext
        guard let installedApp = try await context.perform({
            (try? context.fetch(InstalledApp.fetchRequest()))?.first { $0.resignedBundleIdentifier == bundleIdentifier }
                ?? InstalledApp.fetchAltStore(in: context).flatMap { $0.resignedBundleIdentifier == bundleIdentifier ? $0 : nil }
        }), let team = installedApp.team, let account = team.account else {
            throw SideStoreOperationError.installedAppUnavailable
        }
        if let selectedAccount, selectedAccount.teamIdentifier != team.identifier {
            throw SideStoreOperationError.incompatibleRefreshAccount
        }
        let accountID = selectedAccount?.accountIdentifier ?? account.identifier
        let teamID = selectedAccount?.teamIdentifier ?? team.identifier
        try SideKickStorageCleanup.beginOperation()
        defer { SideKickStorageCleanup.endOperation() }

        let vpnLease = try await LocalVPNService.shared.acquire()
        defer { LocalVPNService.shared.release(vpnLease) }
        // A refresh only installs new profiles; the app keeps its existing signature. Use the
        // imported certificate only for apps it actually signed, or iOS ignores the profile.
        let importedSerial = ImportedCertificateStore.shared.assignedRecord(
            accountIdentifier: accountID,
            teamIdentifier: teamID
        )?.serialNumber
        let useImportedCertificate = importedSerial.map { Self.isInstalledApp(installedApp, signedWith: $0) } ?? false
        try await retryAfterClearingRevokedAssignedProfile(for: installedApp.bundleIdentifier) {
            try await accountStore.withAccount(
                accountIdentifier: accountID,
                teamIdentifier: teamID,
                useImportedCertificate: useImportedCertificate
            ) {
                try ImportedCertificateStore.shared.prepareProfileAssignment(
                    bundleIdentifiers: [installedApp.bundleIdentifier, installedApp.resignedBundleIdentifier],
                    accountIdentifier: accountID,
                    teamIdentifier: teamID,
                    useImportedCertificate: useImportedCertificate
                )
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let group = RefreshGroup(dbContext: DatabaseManager.shared.persistentContainer.newBackgroundContext())
                    guard !SideKickStorageCleanup.isRemovingFiles else {
                        continuation.resume(throwing: StorageCleanupError.operationRunning)
                        return
                    }
                    let observationBox = ProgressObservationBox()
                    let observation = group.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in progressHandler(fraction) }
                    }
                    observationBox.retain(observation)
                    group.completionHandler = { results in
                        observationBox.finish()
                        guard let result = results[installedApp.bundleIdentifier] else {
                            continuation.resume(throwing: SideStoreOperationError.noRefreshResult)
                            return
                        }
                        continuation.resume(with: result.map { _ in () })
                    }
                    AppManager.shared.refresh([installedApp], presentingViewController: presenter, group: group)
                }
            }
        }
        if updatesExpiryNotifications {
            await ExpirationNotificationScheduler.update()
        }
    }

    func resign(
        bundleIdentifier: String,
        using selectedAccount: SigningAccountSummary,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
        try await SideKickDiagnostics.perform(.resign, stage: .signing) {
            try await performResign(bundleIdentifier: bundleIdentifier, using: selectedAccount, progressHandler: progressHandler)
        }
    }

    private func performResign(
        bundleIdentifier: String,
        using selectedAccount: SigningAccountSummary,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard !AppOffloadService.isRunning else { throw AppOffloadError.inUse }
        guard !AppOffloadService.blocksNativeOperations(bundleIdentifier) else { throw AppOffloadError.restoreRequired }
        guard let presenter = UIApplication.shared.topViewController() else {
            throw SideStoreOperationError.presentationUnavailable
        }
        let context = DatabaseManager.shared.viewContext
        guard let installedApp = try await context.perform({
            (try? context.fetch(InstalledApp.fetchRequest()))?.first { $0.resignedBundleIdentifier == bundleIdentifier }
                ?? InstalledApp.fetchAltStore(in: context).flatMap { $0.resignedBundleIdentifier == bundleIdentifier ? $0 : nil }
        }), let team = installedApp.team, team.account != nil else {
            throw SideStoreOperationError.installedAppUnavailable
        }
        guard selectedAccount.teamIdentifier == team.identifier else {
            throw SideStoreOperationError.incompatibleRefreshAccount
        }

        try SideKickStorageCleanup.beginOperation()
        defer { SideKickStorageCleanup.endOperation() }

        let vpnLease = try await LocalVPNService.shared.acquire()
        defer { LocalVPNService.shared.release(vpnLease) }
        try await retryAfterClearingRevokedAssignedProfile(for: installedApp.bundleIdentifier) {
            try await accountStore.withAccount(
                accountIdentifier: selectedAccount.accountIdentifier,
                teamIdentifier: selectedAccount.teamIdentifier,
                forceRefreshCertificate: true
            ) {
                try ImportedCertificateStore.shared.prepareProfileAssignment(
                    bundleIdentifiers: [installedApp.bundleIdentifier, installedApp.resignedBundleIdentifier],
                    accountIdentifier: selectedAccount.accountIdentifier,
                    teamIdentifier: selectedAccount.teamIdentifier
                )
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard !SideKickStorageCleanup.isRemovingFiles else {
                        continuation.resume(throwing: StorageCleanupError.operationRunning)
                        return
                    }
                    let observationBox = ProgressObservationBox()
                    let group = AppManager.shared.resign(installedApp, presentingViewController: presenter) { result in
                        observationBox.finish()
                        continuation.resume(with: result.map { _ in () })
                    }
                    let observation = group.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in progressHandler(fraction) }
                    }
                    observationBox.retain(observation)
                }
            }
        }
        await ExpirationNotificationScheduler.update()
    }

    /// Whether the certificate with `serialNumber` signed the installed copy of the app.
    /// SideKick reads its own embedded certificate ID; other apps are checked against the
    /// profile embedded in their cached signed bundle. Needs device testing.
    static func isInstalledApp(_ installedApp: InstalledApp, signedWith serialNumber: String) -> Bool {
        let target = ImportedCertificateCatalog.normalizedSerial(serialNumber)
        if let recorded = installedApp.certificateSerialNumber {
            return ImportedCertificateCatalog.normalizedSerial(recorded) == target
        }
        if installedApp.resignedBundleIdentifier == Bundle.Info.activeBundleIdentifier {
            let embedded = Bundle.main.object(forInfoDictionaryKey: Bundle.Info.certificateID) as? String
            return embedded.map(ImportedCertificateCatalog.normalizedSerial) == target
        }
        guard let profile = ALTApplication(fileURL: installedApp.fileURL)?.provisioningProfile else { return false }
        return profile.certificates.contains { ImportedCertificateCatalog.normalizedSerial($0.serialNumber) == target }
    }

    /// Updates keep the certificate that signed the installed copy, so its data and team
    /// stay the same even if the account's certificate choice changed since. New installs
    /// follow the account's choice.
    private func importedCertificateUse(forUpdateOf targetID: String?, using account: SigningAccountSummary) async throws -> Bool {
        let store = ImportedCertificateStore.shared
        let assigned = store.assignedRecord(accountIdentifier: account.accountIdentifier, teamIdentifier: account.teamIdentifier)
        guard let targetID else { return assigned != nil }
        let context = DatabaseManager.shared.viewContext
        let installed: InstalledApp? = await context.perform {
            (try? context.fetch(InstalledApp.fetchRequest()))?.first { $0.resignedBundleIdentifier == targetID }
                ?? InstalledApp.fetchAltStore(in: context).flatMap { $0.resignedBundleIdentifier == targetID ? $0 : nil }
        }
        guard let installed else { return assigned != nil }
        let signingRecord = store.catalog.certificates.first { Self.isInstalledApp(installed, signedWith: $0.serialNumber) }
        guard let signingRecord else { return false }
        guard let assigned, ImportedCertificateCatalog.normalizedSerial(assigned.serialNumber)
                == ImportedCertificateCatalog.normalizedSerial(signingRecord.serialNumber) else {
            throw ImportedCertificateError.updateCertificateMismatch(certificateName: signingRecord.name)
        }
        return true
    }

    /// An imported profile for one specific App ID can sign only one app: every app signed
    /// with it gets that bundle ID, so a second app would silently replace the first.
    private func ensureImportedProfileIsFree(for ipa: ImportedIPA, using account: SigningAccountSummary) async throws {
        guard let record = ImportedCertificateStore.shared.assignedRecord(
            accountIdentifier: account.accountIdentifier,
            teamIdentifier: account.teamIdentifier
        ), let profile = record.profile, !profile.appIdentifier.hasSuffix("*") else { return }

        let incoming = Set([ipa.bundleIdentifier] + [ipa.queuedForInstalledAppID].compactMap { $0 })
        let context = DatabaseManager.shared.viewContext
        let occupant: String? = await context.perform {
            let apps = (try? context.fetch(InstalledApp.fetchRequest())) ?? []
            return apps.first {
                $0.resignedBundleIdentifier == profile.appIdentifier &&
                    !incoming.contains($0.bundleIdentifier) && !incoming.contains($0.resignedBundleIdentifier)
            }?.name
        }
        if let occupant {
            throw ImportedCertificateError.profileInUse(appName: occupant, appIdentifier: profile.appIdentifier)
        }
    }

    private func retryAfterClearingRevokedAssignedProfile<T>(
        for bundleIdentifier: String,
        recoveryHandler: @escaping @MainActor @Sendable () -> Void = {},
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let error as OperationError {
            guard case .customCertificateRevoked = error,
                  ProfileManager.shared.getAssignedProfile(for: bundleIdentifier) != nil else {
                throw error
            }

            ProfileManager.shared.setAssignedProfile(nil, for: bundleIdentifier)
            debugLog("[SideKick] Cleared revoked assigned profile for \(bundleIdentifier); retrying with the selected Apple ID certificate.")
            recoveryHandler()
            return try await operation()
        }
    }

    static func pruneUnusedCaches() async {
        await SideKickStorageCleanup.performAutomaticMaintenance()
    }

    func enableJIT(bundleIdentifier: String) async throws {
        guard !AppOffloadService.isRunning else { throw AppOffloadError.inUse }
        guard !AppOffloadService.blocksNativeOperations(bundleIdentifier) else { throw AppOffloadError.restoreRequired }
        let context = DatabaseManager.shared.viewContext
        guard let installedApp = try await context.perform({
            (try? context.fetch(InstalledApp.fetchRequest()))?.first { $0.resignedBundleIdentifier == bundleIdentifier }
                ?? InstalledApp.fetchAltStore(in: context).flatMap { $0.resignedBundleIdentifier == bundleIdentifier ? $0 : nil }
        }) else {
            throw SideStoreOperationError.installedAppUnavailable
        }

        try SideKickStorageCleanup.beginOperation()
        defer { SideKickStorageCleanup.endOperation() }
        let vpnLease = try await LocalVPNService.shared.acquire()
        defer { LocalVPNService.shared.release(vpnLease) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            AppManager.shared.enableJIT(for: installedApp) { result in
                continuation.resume(with: result.map { _ in () })
            }
        }
    }

    func refreshAllManagedAppsQuietly(
        progressHandler: @escaping @MainActor @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> QuietRefreshOutcome {
        let apps: [InstalledAppSummary]
        do {
            apps = try await loadInstalledApps().filter { app in
                guard app.isActive, !AppOffloadService.blocksNativeOperations(app.id) else { return false }
                // Imported certificates last months; refreshing them weekly reinstalls the same
                // profile and gains nothing. Only touch them once they're close to expiring.
                if app.importedCertificate != nil {
                    return app.expirationDate.timeIntervalSinceNow < 7 * 24 * 60 * 60
                }
                return true
            }
        }
        catch {
            debugLog("[SideKick] Couldn’t load installed apps for scheduled refresh: \(error.localizedDescription)")
            return QuietRefreshOutcome(succeeded: 0, attempted: 0, failure: .appListUnavailable,
                appResults: [], failureMessage: error.localizedDescription)
        }
        guard !apps.isEmpty else {
            await ExpirationNotificationScheduler.update()
            return QuietRefreshOutcome(succeeded: 0, attempted: 0, failure: .noEligibleApps,
                appResults: [], failureMessage: nil)
        }

        do { try SideKickStorageCleanup.beginOperation() }
        catch {
            debugLog("[SideKick] Deferred scheduled refresh while storage cleanup is running.")
            return QuietRefreshOutcome(succeeded: 0, attempted: apps.count, failure: .operationUnavailable,
                appResults: apps.map { app in .failure(for: app, reason: error.localizedDescription, recovery: nil) },
                failureMessage: error.localizedDescription)
        }
        defer { SideKickStorageCleanup.endOperation() }

        let vpnLease: UUID
        do { vpnLease = try await LocalVPNService.shared.acquire() }
        catch {
            debugLog("[SideKick] Could not connect for refresh: \(error.localizedDescription)")
            progressHandler(apps.count, apps.count)
            return QuietRefreshOutcome(succeeded: 0, attempted: apps.count, failure: .connectionUnavailable,
                appResults: apps.map { app in .failure(for: app, reason: error.localizedDescription, recovery: .localConnection) },
                failureMessage: error.localizedDescription)
        }
        defer { LocalVPNService.shared.release(vpnLease) }

        var succeeded = 0
        var appResults: [ManagedAppRefreshResult] = []
        for (index, app) in apps.enumerated() {
            do {
                try await refresh(
                    bundleIdentifier: app.id,
                    requiresPresenter: false,
                    updatesExpiryNotifications: false
                )
                succeeded += 1
                appResults.append(.success(for: app))
            } catch {
                // Scheduled attempts are intentionally quiet; the next automation retries failures.
                debugLog("[SideKick] Scheduled refresh failed for \(app.bundleIdentifier): \(error.localizedDescription)")
                appResults.append(.failure(for: app, reason: AnisetteErrorHint.message(for: error),
                    recovery: error is LocalVPNError ? .localConnection : .account))
            }
            progressHandler(index + 1, apps.count)
        }
        await ExpirationNotificationScheduler.update()
        return QuietRefreshOutcome(
            succeeded: succeeded,
            attempted: apps.count,
            failure: succeeded == apps.count ? nil : .appRefreshFailed,
            appResults: appResults,
            failureMessage: nil
        )
    }

    func retryFailedManagedApps(
        _ failedApps: [ManagedAppRefreshResult],
        progressHandler: @escaping @MainActor @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> [ManagedAppRefreshResult] {
        let failures = failedApps.filter { !$0.succeeded }
        var results: [ManagedAppRefreshResult] = []
        for (index, previous) in failures.enumerated() {
            do {
                try await refresh(bundleIdentifier: previous.appID)
                var result = previous
                result.succeeded = true
                result.failureMessage = nil
                result.recovery = nil
                results.append(result)
            } catch {
                var result = previous
                result.failureMessage = AnisetteErrorHint.message(for: error)
                result.recovery = error is LocalVPNError ? .localConnection : .account
                results.append(result)
            }
            progressHandler(index + 1, failures.count)
        }
        return results
    }
}

enum ManagedAppRefreshRecovery: Equatable, Sendable {
    case account, localConnection
}

struct ManagedAppRefreshResult: Identifiable, Equatable, Sendable {
    let appID: String
    let appName: String
    let accountIdentifier: String
    let teamIdentifier: String
    let accountEmail: String
    var succeeded: Bool
    var failureMessage: String?
    var recovery: ManagedAppRefreshRecovery?

    var id: String { appID }

    static func success(for app: InstalledAppSummary) -> Self {
        Self(appID: app.id, appName: app.name, accountIdentifier: app.accountIdentifier,
            teamIdentifier: app.teamIdentifier, accountEmail: app.accountEmail, succeeded: true,
            failureMessage: nil, recovery: nil)
    }

    static func failure(for app: InstalledAppSummary, reason: String, recovery: ManagedAppRefreshRecovery?) -> Self {
        Self(appID: app.id, appName: app.name, accountIdentifier: app.accountIdentifier,
            teamIdentifier: app.teamIdentifier, accountEmail: app.accountEmail, succeeded: false,
            failureMessage: reason, recovery: recovery)
    }
}

struct QuietRefreshOutcome {
    enum Failure {
        case noEligibleApps
        case appListUnavailable
        case operationUnavailable
        case connectionUnavailable
        case appRefreshFailed
    }

    var succeeded: Int
    var attempted: Int
    var failure: Failure?
    var appResults: [ManagedAppRefreshResult]
    var failureMessage: String?
}

final class ProgressObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var isFinished = false

    func retain(_ observation: NSKeyValueObservation) {
        lock.lock()
        let shouldInvalidate = isFinished
        if !shouldInvalidate { self.observation = observation }
        lock.unlock()
        if shouldInvalidate { observation.invalidate() }
    }

    func finish() {
        lock.lock()
        isFinished = true
        let observation = self.observation
        self.observation = nil
        lock.unlock()
        observation?.invalidate()
    }
}

struct InstalledAppSummary: Identifiable, Sendable {
    let bundleIdentifier: String
    var updateTarget: GitHubUpdateTarget {
        let legacy = [version, buildVersion, contentFingerprint ?? "no-content-fingerprint"].joined(separator: "|")
        let observation = executableIdentity.map { [version, buildVersion, "mach-o:" + $0].joined(separator: "|") }
            ?? contentFingerprint.map { [version, buildVersion, $0].joined(separator: "|") }
        return GitHubUpdateTarget(id: id, name: name, version: version, observation: observation, legacyObservation: legacy)
    }
    let resignedBundleIdentifier: String
    let name: String
    let version: String
    let buildVersion: String
    let accountEmail: String
    let accountIdentifier: String
    let teamIdentifier: String
    var iconData: Data?
    let expirationDate: Date
    var contentFingerprint: String? = nil
    var executableIdentity: String? = nil
    var isActive: Bool = true
    /// Serial of the certificate that signed the installed copy, when SideKick knows it.
    var signingCertificateSerial: String? = nil

    var id: String { resignedBundleIdentifier }

    /// The imported certificate that signed this app, if any.
    @MainActor var importedCertificate: ImportedCertificateRecord? {
        signingCertificateSerial.flatMap { ImportedCertificateStore.shared.catalog.record(matchingSerial: $0) }
    }

    /// SideStore adds the signing team's identifier to this app's installed bundle ID.
    /// GitHub builds retain the stable, unsuffixed product identifier.
    var updateMatchingBundleIdentifiers: Set<String> {
        let identifiers = [bundleIdentifier, resignedBundleIdentifier].map { $0.lowercased() }
        let sideKickBundleID = "com.sidekick.app"
        var result = Set(identifiers)
        let teamQualifiedSideKickBundleID = "\(sideKickBundleID).\(teamIdentifier)".lowercased()
        if identifiers.contains(where: { $0 == sideKickBundleID || $0 == teamQualifiedSideKickBundleID }) {
            result.insert(sideKickBundleID)
        }
        return result
    }
}

private enum SideStoreOperationError: LocalizedError {
    case presentationUnavailable
    case installedAppUnavailable
    case incompatibleRefreshAccount
    case noRefreshResult

    var errorDescription: String? {
        switch self {
        case .presentationUnavailable: "SideKick couldn’t open the signing operation. Try again."
        case .installedAppUnavailable: "This installed app or its signing account is no longer available."
        case .incompatibleRefreshAccount: "Refreshing must keep the app on its current signing team. Choose an account on the same team."
        case .noRefreshResult: "The refresh operation finished without returning a result."
        }
    }
}
