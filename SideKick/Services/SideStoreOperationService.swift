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

            return candidates.compactMap { app -> (InstalledApp, String, String, String, String, String, String, String, Date)? in
                guard let team = app.team, let account = team.account else { return nil }
                return (
                    app,
                    app.bundleIdentifier,
                    app.resignedBundleIdentifier,
                    app.name,
                    app.version,
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
                accountEmail: record.5,
                accountIdentifier: record.6,
                teamIdentifier: record.7,
                iconData: iconData,
                expirationDate: record.8
            ))
        }
        return summaries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func install(
        _ ipa: ImportedIPA,
        using account: SigningAccountSummary,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard let presenter = UIApplication.shared.topViewController() else {
            throw SideStoreOperationError.presentationUnavailable
        }
        let url = try await ipaStore.fileURL(for: ipa)
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

    func refresh(bundleIdentifier: String) async throws {
        guard let presenter = UIApplication.shared.topViewController() else {
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

        try await accountStore.withAccount(accountIdentifier: accountID, teamIdentifier: teamID) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let group = RefreshGroup(dbContext: DatabaseManager.shared.persistentContainer.newBackgroundContext())
                group.completionHandler = { results in
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

struct InstalledAppSummary: Identifiable {
    let bundleIdentifier: String
    let resignedBundleIdentifier: String
    let name: String
    let version: String
    let accountEmail: String
    let accountIdentifier: String
    let teamIdentifier: String
    let iconData: Data?
    let expirationDate: Date

    var id: String { bundleIdentifier }
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
