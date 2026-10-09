import CoreData
import Foundation
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
        return await context.perform {
            InstalledApp.fetchActiveApps(in: context).compactMap { app in
                guard let team = app.team, let account = team.account else { return nil }
                return InstalledAppSummary(
                    bundleIdentifier: app.bundleIdentifier,
                    name: app.name,
                    accountEmail: account.appleID,
                    accountIdentifier: account.identifier,
                    teamIdentifier: team.identifier
                )
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func install(_ ipa: ImportedIPA, using account: SigningAccountSummary) async throws {
        guard let presenter = UIApplication.shared.topViewController() else {
            throw SideStoreOperationError.presentationUnavailable
        }
        let url = try await ipaStore.fileURL(for: ipa)
        try await accountStore.withAccount(
            accountIdentifier: account.accountIdentifier,
            teamIdentifier: account.teamIdentifier
        ) {
            try await withCheckedThrowingContinuation { continuation in
                AppManager.shared.install(.url(url), presentingViewController: presenter) { result in
                    continuation.resume(with: result.map { _ in () })
                }
            }
        }
    }

    func refresh(bundleIdentifier: String) async throws {
        guard let presenter = UIApplication.shared.topViewController() else {
            throw SideStoreOperationError.presentationUnavailable
        }
        let context = DatabaseManager.shared.viewContext
        guard let installedApp = try await context.perform({
            InstalledApp.fetchActiveApps(in: context).first { $0.bundleIdentifier == bundleIdentifier }
        }), let team = installedApp.team, let account = team.account else {
            throw SideStoreOperationError.installedAppUnavailable
        }
        let accountID = account.identifier
        let teamID = team.identifier

        try await accountStore.withAccount(accountIdentifier: accountID, teamIdentifier: teamID) {
            try await withCheckedThrowingContinuation { continuation in
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

struct InstalledAppSummary: Identifiable {
    let bundleIdentifier: String
    let name: String
    let accountEmail: String
    let accountIdentifier: String
    let teamIdentifier: String

    var id: String { bundleIdentifier }
}

private enum SideStoreOperationError: LocalizedError {
    case presentationUnavailable
    case installedAppUnavailable
    case noRefreshResult

    var errorDescription: String? {
        switch self {
        case .presentationUnavailable: "SideKick couldn’t open the signing operation. Try again."
        case .installedAppUnavailable: "This installed app or its signing account is no longer available in SideStore."
        case .noRefreshResult: "SideStore finished without returning a refresh result."
        }
    }
}
