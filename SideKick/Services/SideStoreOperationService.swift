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
        let context = DatabaseManager.shared.viewContext
        let records = await context.perform {
            let selfTeamIdentifier = ALTApplication(fileURL: Bundle.Info.activeBundleURL)?
                .provisioningProfile?.teamIdentifier
            let apps = (try? context.fetch(InstalledApp.fetchRequest())) ?? []
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

            return candidates.compactMap { app -> (InstalledApp, String, String, String, String, String, String, String, String, Date)? in
                guard let team = app.team, let account = team.account else { return nil }
                return (
                    app,
                    app.bundleIdentifier,
                    app.resignedBundleIdentifier,
                    app.name,
                    app.version,
                    app.buildVersion,
                    account.appleID,
                    account.identifier,
                    team.identifier,
                    app.expirationDate
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
                expirationDate: record.9
            ))
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
        let url = try await ipaStore.fileURL(for: ipa)
        defer { try? FileManager.default.removeItem(at: url) }
        try await retryAfterClearingRevokedAssignedProfile(
            for: ipa.bundleIdentifier,
            recoveryHandler: recoveryHandler
        ) {
            try await accountStore.withAccount(
                accountIdentifier: account.accountIdentifier,
                teamIdentifier: account.teamIdentifier
            ) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let observationBox = ProgressObservationBox()
                    let group = AppManager.shared.install(.url(url), presentingViewController: presenter) { result in
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
        await Self.pruneUnusedCaches()
        await ExpirationNotificationScheduler.update()
    }

    func refresh(
        bundleIdentifier: String,
        requiresPresenter: Bool = true,
        updatesExpiryNotifications: Bool = true,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let presenter = UIApplication.shared.topViewController()
        guard !requiresPresenter || presenter != nil else {
            throw SideStoreOperationError.presentationUnavailable
        }
        let context = DatabaseManager.shared.viewContext
        guard let installedApp = try await context.perform({
            (try? context.fetch(InstalledApp.fetchRequest()))?.first { $0.bundleIdentifier == bundleIdentifier }
                ?? InstalledApp.fetchAltStore(in: context).flatMap { $0.bundleIdentifier == bundleIdentifier ? $0 : nil }
        }), let team = installedApp.team, let account = team.account else {
            throw SideStoreOperationError.installedAppUnavailable
        }
        let accountID = account.identifier
        let teamID = team.identifier

        try await retryAfterClearingRevokedAssignedProfile(for: bundleIdentifier) {
            try await accountStore.withAccount(accountIdentifier: accountID, teamIdentifier: teamID) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let group = RefreshGroup(dbContext: DatabaseManager.shared.persistentContainer.newBackgroundContext())
                    let observationBox = ProgressObservationBox()
                    let observation = group.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in progressHandler(fraction) }
                    }
                    observationBox.retain(observation)
                    group.completionHandler = { results in
                        observationBox.finish()
                        guard let result = results[bundleIdentifier] else {
                            continuation.resume(throwing: SideStoreOperationError.noRefreshResult)
                            return
                        }
                        continuation.resume(with: result.map { _ in () })
                    }
                    AppManager.shared.refresh([installedApp], presentingViewController: presenter, group: group)
                }
            }
        }
        await Self.pruneUnusedCaches()
        if updatesExpiryNotifications {
            await ExpirationNotificationScheduler.update()
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
        guard DatabaseManager.shared.isStarted else { return }

        let context = DatabaseManager.shared.viewContext
        let references = await context.perform { () -> (bundleIdentifiers: Set<String>, signatures: Set<String>)? in
            guard let apps = try? context.fetch(InstalledApp.fetchRequest()) else { return nil }
            let retainedApps = apps.filter { !$0.isDeleted }
            return (
                Set(retainedApps.map(\.resignedBundleIdentifier)),
                Set(retainedApps.compactMap(\.appBundleFingerprint))
            )
        }
        guard let references else {
            debugLog("[SideKick] Skipped cache pruning because installed apps could not be read.")
            return
        }

        CacheAppOperation.pruneUnusedCaches(
            activeSignatures: references.signatures,
            activeBundleIDs: references.bundleIdentifiers
        ) { bundleIdentifier in
            AppManager.shared.isActivelyManagingApp(withBundleID: bundleIdentifier)
        }
    }

    func enableJIT(bundleIdentifier: String) async throws {
        let context = DatabaseManager.shared.viewContext
        guard let installedApp = try await context.perform({
            (try? context.fetch(InstalledApp.fetchRequest()))?.first { $0.bundleIdentifier == bundleIdentifier }
                ?? InstalledApp.fetchAltStore(in: context).flatMap { $0.bundleIdentifier == bundleIdentifier ? $0 : nil }
        }) else {
            throw SideStoreOperationError.installedAppUnavailable
        }

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

        var succeeded = 0
        for (index, app) in apps.enumerated() {
            do {
                try await refresh(
                    bundleIdentifier: app.bundleIdentifier,
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
    let resignedBundleIdentifier: String
    let name: String
    let version: String
    let buildVersion: String
    let accountEmail: String
    let accountIdentifier: String
    let teamIdentifier: String
    let iconData: Data?
    let expirationDate: Date

    var id: String { bundleIdentifier }

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
    case noRefreshResult

    var errorDescription: String? {
        switch self {
        case .presentationUnavailable: "SideKick couldn’t open the signing operation. Try again."
        case .installedAppUnavailable: "This installed app or its signing account is no longer available."
        case .noRefreshResult: "The refresh operation finished without returning a result."
        }
    }
}
