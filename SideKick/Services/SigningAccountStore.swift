import CoreData
import Foundation
import Observation
import Security
import UIKit

struct SigningAccountSummary: Identifiable, Equatable {
    let accountIdentifier: String
    let teamIdentifier: String
    let email: String
    let teamName: String
    let teamType: String
    let isActive: Bool
    let hasSavedSession: Bool

    var id: String { "\(accountIdentifier)|\(teamIdentifier)" }
}

@MainActor
@Observable
final class SigningAccountStore {
    private(set) var accounts: [SigningAccountSummary] = []
    private(set) var isWorking = false

    private let vault = SigningSessionVault()

    func reload() async {
        guard DatabaseManager.shared.isStarted else {
            accounts = []
            return
        }

        let context = DatabaseManager.shared.viewContext
        do {
            let records = try await context.perform {
                let request = Account.fetchRequest()
                return try context.fetch(request).flatMap { account in
                    account.teams.map { team in
                        (account.identifier,
                         team.identifier,
                         account.appleID,
                         team.name,
                         team.type.localizedDescription,
                         team.isActiveTeam)
                    }
                }
            }

            accounts = records.map { record in
                let key = SigningSessionVault.key(accountIdentifier: record.0, teamIdentifier: record.1)
                return SigningAccountSummary(
                    accountIdentifier: record.0,
                    teamIdentifier: record.1,
                    email: record.2,
                    teamName: record.3,
                    teamType: record.4,
                    isActive: record.5,
                    hasSavedSession: (try? vault.load(key: key)) != nil
                )
            }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.email.localizedCaseInsensitiveCompare(rhs.email) == .orderedAscending
            }
        } catch {
            accounts = []
            debugLog("[SideKick] Failed to load signing accounts: \(error)")
        }
    }

    func addAccount() async throws {
        guard !isWorking else { return }
        guard !AppManager.shared.isActivelyManagingAnyApp else {
            throw SigningAccountError.engineBusy
        }
        guard let presenter = UIApplication.shared.topViewController() else {
            throw SigningAccountError.presentationUnavailable
        }

        isWorking = true
        defer { isWorking = false }

        let result = try await AuthManager.shared.signIn(presentingViewController: presenter)
        let accountIdentifier = result.team.account?.identifier ?? result.team.identifier
        guard let email = AuthManager.shared.currentAppleID,
              let password = AuthManager.shared.password,
              let adsid = AuthManager.shared.adsid,
              let xcodeToken = AuthManager.shared.xcodeToken else {
            throw SigningAccountError.sessionNotAvailable
        }

        let certificate = CertificateManager.shared.activeCertificate
        let credentials = SigningSessionCredentials(
            appleID: email,
            password: password,
            adsid: adsid,
            xcodeToken: xcodeToken,
            accountIdentifier: accountIdentifier,
            teamIdentifier: result.team.identifier,
            certificateData: certificate?.p12Data,
            certificatePassword: certificate?.password
        )
        try vault.save(credentials, key: SigningSessionVault.key(
            accountIdentifier: accountIdentifier,
            teamIdentifier: result.team.identifier
        ))
        await reload()
    }

    func activate(_ account: SigningAccountSummary) async throws {
        guard !isWorking else { return }
        guard !AppManager.shared.isActivelyManagingAnyApp else {
            throw SigningAccountError.engineBusy
        }
        isWorking = true
        defer { isWorking = false }

        let key = SigningSessionVault.key(
            accountIdentifier: account.accountIdentifier,
            teamIdentifier: account.teamIdentifier
        )
        let credentials = try vault.load(key: key)
        let signingCertificate = try credentials.certificateData.map {
            try CertificateManager.parse($0, password: credentials.certificatePassword)
        }

        // AuthManager and CertificateManager are process-global in SideStore. Clear their
        // cached identity before restoring this account's saved credentials and certificate.
        await AuthManager.shared.signOut(keepCertificate: true, keepAnisetteData: true)
        AuthManager.shared.currentAppleID = credentials.appleID
        AuthManager.shared.password = credentials.password
        AuthManager.shared.adsid = credentials.adsid
        AuthManager.shared.xcodeToken = credentials.xcodeToken

        let database = DatabaseManager.shared
        let context = database.persistentContainer.newBackgroundContext()
        try await context.perform {
            let accounts = try context.fetch(Account.fetchRequest())
            let teams = try context.fetch(Team.fetchRequest())
            guard let selectedAccount = accounts.first(where: { $0.identifier == credentials.accountIdentifier }),
                  let selectedTeam = teams.first(where: {
                      $0.identifier == credentials.teamIdentifier &&
                      $0.account.identifier == credentials.accountIdentifier
                  }) else {
                throw SigningAccountError.savedAccountMissing
            }
            for savedAccount in accounts {
                savedAccount.isActiveAccount = savedAccount == selectedAccount
            }
            for savedTeam in teams {
                savedTeam.isActiveTeam = savedTeam == selectedTeam
            }

            let isSparseRestorePatched = ProcessInfo().sparseRestorePatched
            let isAppLimitDisabled = UserDefaults.standard.isAppLimitDisabled
            UserDefaults.standard.activeAppsLimit = nil
            if selectedTeam.type == .free,
               (!isAppLimitDisabled && isSparseRestorePatched || isAppLimitDisabled && !isSparseRestorePatched) {
                UserDefaults.standard.activeAppsLimit = InstalledApp.freeAccountActiveAppsLimit
            }

            try context.save()
        }

        if let signingCertificate {
            try CertificateManager.shared.setActiveCertificate(signingCertificate)
        } else {
            CertificateManager.shared.clearActiveCertificate()
        }

        await reload()
    }
}

private struct SigningSessionCredentials: Codable {
    let appleID: String
    let password: String
    let adsid: String
    let xcodeToken: String
    let accountIdentifier: String
    let teamIdentifier: String
    let certificateData: Data?
    let certificatePassword: String?
}

private struct SigningSessionVault {
    private let service = "com.sidekick.account-sessions"

    static func key(accountIdentifier: String, teamIdentifier: String) -> String {
        "\(accountIdentifier).\(teamIdentifier)"
    }

    func save(_ credentials: SigningSessionCredentials, key: String) throws {
        let data = try JSONEncoder().encode(credentials)
        var query = baseQuery(key: key)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SigningAccountError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw SigningAccountError.keychain(status)
        }
    }

    func load(key: String) throws -> SigningSessionCredentials {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw SigningAccountError.keychain(status)
        }
        return try JSONDecoder().decode(SigningSessionCredentials.self, from: data)
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

private enum SigningAccountError: LocalizedError {
    case presentationUnavailable
    case engineBusy
    case sessionNotAvailable
    case savedAccountMissing
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .presentationUnavailable:
            return "SideKick couldn’t open Apple’s sign-in sheet. Please try again."
        case .engineBusy:
            return "SideKick can’t change accounts while SideStore is installing or refreshing an app. Wait for that operation to finish and try again."
        case .sessionNotAvailable:
            return "SideStore completed sign-in but did not return a complete Apple ID session. This account was not saved."
        case .savedAccountMissing:
            return "This account or team is missing from SideStore’s database. Sign in again to restore it."
        case .keychain(let status):
            return "SideKick couldn’t securely save or load this Apple ID session (Keychain status \(status))."
        }
    }
}
