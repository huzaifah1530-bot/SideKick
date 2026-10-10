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

    func loadInstalledApps() async throws -> [InstalledAppSummary] {
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
            return candidates.map { app -> (InstalledApp, String, String, String, String, String, String, String, String, Date, String?, String?) in
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
                    runningBundle != nil ? runningIdentity : app.appBundleFingerprint
                )
            }
        }

        var summaries: [InstalledAppSummary] = []
        for record in records {
            let iconData = try? await record.0.loadIcon()?.pngData()
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
                executableIdentity: record.10
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
        }
        return summaries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func install(
        _ ipa: ImportedIPA,
        using account: SigningAccountSummary,
        recoveryHandler: @escaping @MainActor @Sendable () -> Void = {},
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
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
            installedID = try await retryAfterClearingRevokedAssignedProfile(
                for: ipa.bundleIdentifier,
                recoveryHandler: recoveryHandler
            ) {
                try await accountStore.withAccount(
                    accountIdentifier: account.accountIdentifier,
                    teamIdentifier: account.teamIdentifier
                ) {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
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
            if let origin = ipa.githubImportConfiguration {
                _ = try await store.recordSuccessfulImport(origin, key: key, for: target)
            } else if let expectedSource = ipa.githubSourceIdentity, ipa.queuedForInstalledAppID == target.id {
                _ = try await store.recordInstalled(key: key, for: target, expectedSource: expectedSource)
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
        let presenter = UIApplication.shared.topViewController()
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
        try await retryAfterClearingRevokedAssignedProfile(for: installedApp.bundleIdentifier) {
            try await accountStore.withAccount(accountIdentifier: accountID, teamIdentifier: teamID) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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
    ) async -> (succeeded: Int, attempted: Int) {
        let apps = await installedApps()
        guard !apps.isEmpty else {
            await ExpirationNotificationScheduler.update()
            return (0, 0)
        }

        do { try SideKickStorageCleanup.beginOperation() }
        catch {
            debugLog("[SideKick] Deferred scheduled refresh while storage cleanup is running.")
            return (0, apps.count)
        }
        defer { SideKickStorageCleanup.endOperation() }

        let vpnLease: UUID
        do { vpnLease = try await LocalVPNService.shared.acquire() }
        catch {
            debugLog("[SideKick] Could not connect for refresh: \(error.localizedDescription)")
            progressHandler(apps.count, apps.count)
            return (0, apps.count)
        }
        defer { LocalVPNService.shared.release(vpnLease) }

        var succeeded = 0
        for (index, app) in apps.enumerated() {
            do {
                try await refresh(
                    bundleIdentifier: app.id,
                    requiresPresenter: false,
                    updatesExpiryNotifications: false
                )
                succeeded += 1
            } catch {
                // Scheduled attempts are intentionally quiet; the next automation retries failures.
                debugLog("[SideKick] Scheduled refresh failed for \(app.bundleIdentifier): \(error.localizedDescription)")
            }
            progressHandler(index + 1, apps.count)
        }
        await ExpirationNotificationScheduler.update()
        return (succeeded, apps.count)
    }
}

private final class ProgressObservationBox: @unchecked Sendable {
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
    let iconData: Data?
    let expirationDate: Date
    var contentFingerprint: String? = nil
    var executableIdentity: String? = nil

    var id: String { resignedBundleIdentifier }

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
