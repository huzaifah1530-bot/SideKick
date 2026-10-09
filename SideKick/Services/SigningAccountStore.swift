import CoreData
import Foundation
import Observation
import Security
import SideSign
import UIKit

struct SigningAccountSummary: Identifiable, Equatable {
    let accountIdentifier: String
    let teamIdentifier: String
    let email: String
    let teamName: String
    let teamType: String
    let isFreeAccount: Bool
    let hasSavedSession: Bool

    var id: String { "\(accountIdentifier)|\(teamIdentifier)" }
}

@MainActor
@Observable
final class SigningAccountStore {
    private(set) var accounts: [SigningAccountSummary] = []
    private(set) var isWorking = false
    private(set) var signInCheckpoint = UserDefaults.standard.string(forKey: "sidekick.sign-in-checkpoint")

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
                         team.type == .free)
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
                    isFreeAccount: record.5,
                    hasSavedSession: (try? vault.load(key: key)) != nil
                )
            }
            .sorted { lhs, rhs in
                return lhs.email.localizedCaseInsensitiveCompare(rhs.email) == .orderedAscending
            }
        } catch {
            accounts = []
            debugLog("[SideKick] Failed to load signing accounts: \(error)")
        }
    }

    func addAccount(appleID: String, password: String) async throws {
        guard !isWorking else { return }
        guard DatabaseManager.shared.isStarted else {
            throw SigningAccountError.databaseUnavailable
        }
        guard !AppManager.shared.isActivelyManagingAnyApp else {
            throw SigningAccountError.engineBusy
        }
        guard let presenter = UIApplication.shared.topViewController() else {
            throw SigningAccountError.presentationUnavailable
        }

        isWorking = true
        defer { isWorking = false }

        setSignInCheckpoint("Starting Apple ID authentication")
        let previousAccount = await activeAccountSummary()
        if let previousAccount,
           let previousCredentials = try? currentSessionCredentials(for: previousAccount) {
            try? vault.save(
                previousCredentials,
                key: SigningSessionVault.key(
                    accountIdentifier: previousAccount.accountIdentifier,
                    teamIdentifier: previousAccount.teamIdentifier
                )
            )
        }

        let handler = SideKickSignInFlowHandler(
            presentingViewController: presenter,
            appleID: appleID,
            password: password,
            onAuthenticationSuccess: { [weak self] in
                self?.setSignInCheckpoint("Apple authentication succeeded; resolving developer team")
            }
        )
        let result: SignInResult
        do {
            result = try await AuthManager.shared.signIn(
                presentingViewController: presenter,
                signInHandler: handler,
                skipDeviceRegistration: true,
                skipCertificateProvisioning: true,
                skipHowTos: true
            )
        } catch {
            setSignInCheckpoint("Sign-in failed before the account could be saved")
            throw error
        }

        setSignInCheckpoint("Apple ID authenticated; saving its signing session")
        let accountIdentifier = result.team.account?.identifier ?? result.team.identifier
        let sessionKey = SigningSessionVault.key(
            accountIdentifier: accountIdentifier,
            teamIdentifier: result.team.identifier
        )
        let existingCredentials = try? vault.load(key: sessionKey)
        let certificateData = existingCredentials?.certificateData
        let certificatePassword = existingCredentials?.certificatePassword
        if let certificateData {
            let certificate = try CertificateManager.parse(certificateData, password: certificatePassword)
            try CertificateManager.shared.setActiveCertificate(certificate)
        } else {
            CertificateManager.shared.clearActiveCertificate()
        }
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
            certificateData: certificateData,
            certificatePassword: certificatePassword
        )
        try vault.save(credentials, key: sessionKey)
        setSignInCheckpoint("Session saved; refreshing the account list")
        await reload()
        setSignInCheckpoint("Account saved successfully")
    }

    private func setSignInCheckpoint(_ value: String) {
        signInCheckpoint = value
        UserDefaults.standard.set(value, forKey: "sidekick.sign-in-checkpoint")
    }

    func remove(_ account: SigningAccountSummary) async throws {
        guard !isWorking else { throw SigningAccountError.engineBusy }
        guard !AppManager.shared.isActivelyManagingAnyApp else {
            throw SigningAccountError.engineBusy
        }
        guard DatabaseManager.shared.isStarted else {
            throw SigningAccountError.databaseUnavailable
        }

        isWorking = true
        defer { isWorking = false }

        let wasActive = await activeAccountSummary()?.accountIdentifier == account.accountIdentifier
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let teamIdentifiers = try await context.perform {
            let request = Account.fetchRequest()
            request.predicate = NSPredicate(format: "%K == %@", #keyPath(Account.identifier), account.accountIdentifier)
            guard let savedAccount = try context.fetch(request).first else {
                throw SigningAccountError.savedAccountMissing
            }
            let teamIdentifiers = savedAccount.teams.map(\.identifier)
            context.delete(savedAccount)
            try context.save()
            return teamIdentifiers
        }

        if wasActive {
            await AuthManager.shared.signOut(keepCertificate: false, keepAnisetteData: true)
        }
        for teamIdentifier in teamIdentifiers {
            try vault.delete(key: SigningSessionVault.key(
                accountIdentifier: account.accountIdentifier,
                teamIdentifier: teamIdentifier
            ))
        }
        await reload()
    }

    func withAccount<T>(
        accountIdentifier: String,
        teamIdentifier: String,
        prepareForSigning: Bool = true,
        operation: () async throws -> T
    ) async throws -> T {
        guard !isWorking else { throw SigningAccountError.engineBusy }
        guard !AppManager.shared.isActivelyManagingAnyApp else {
            throw SigningAccountError.engineBusy
        }

        let target = accounts.first {
            $0.accountIdentifier == accountIdentifier && $0.teamIdentifier == teamIdentifier
        } ?? SigningAccountSummary(
            accountIdentifier: accountIdentifier,
            teamIdentifier: teamIdentifier,
            email: "",
            teamName: "",
            teamType: "",
            isFreeAccount: false,
            hasSavedSession: true
        )
        isWorking = true
        defer { isWorking = false }

        let previous = await activeAccountSummary()
        let previousCredentials: SigningSessionCredentials?
        if let previous {
            let key = SigningSessionVault.key(
                accountIdentifier: previous.accountIdentifier,
                teamIdentifier: previous.teamIdentifier
            )
            previousCredentials = (try? currentSessionCredentials(for: previous)) ?? (try? vault.load(key: key))
        } else {
            previousCredentials = nil
        }

        let sessionMatchesTarget = AuthManager.shared.currentAppleID?.caseInsensitiveCompare(target.email) == .orderedSame
        if previous?.id != target.id || !sessionMatchesTarget {
            try await restoreAccountSession(target, activateTeam: prepareForSigning)
        }

        do {
            if prepareForSigning {
                try await ensureSigningReady(for: target)
            }
            let result = try await operation()
            if (previous?.id != target.id || !sessionMatchesTarget), let previousCredentials {
                try await restoreSession(previousCredentials)
            }
            await reload()
            return result
        } catch {
            if (previous?.id != target.id || !sessionMatchesTarget), let previousCredentials {
                try? await restoreSession(previousCredentials)
            }
            await reload()
            throw error
        }
    }

    func fetchDeveloperInventory(for account: SigningAccountSummary) async throws -> AppleDeveloperInventory {
        guard DatabaseManager.shared.isStarted else {
            throw SigningAccountError.databaseUnavailable
        }

        let accountIdentifier = account.accountIdentifier
        let teamIdentifier = account.teamIdentifier
        let context = DatabaseManager.shared.viewContext
        let team = try await context.perform {
            let request = Team.fetchRequest()
            request.predicate = NSPredicate(
                format: "%K == %@ AND %K == %@",
                #keyPath(Team.identifier), teamIdentifier,
                #keyPath(Team.account.identifier), accountIdentifier
            )
            guard let savedTeam = try context.fetch(request).first else {
                throw SigningAccountError.savedAccountMissing
            }
            return ALTTeam(
                identifier: savedTeam.identifier,
                name: savedTeam.name,
                type: savedTeam.type
            )
        }

        return try await withAccount(
            accountIdentifier: accountIdentifier,
            teamIdentifier: teamIdentifier,
            prepareForSigning: false
        ) {
            async let appIDs = DeveloperPortalProxy.shared.fetchAppIDs(team: team)
            async let profiles = DeveloperPortalProxy.shared.listProvisioningProfiles(team: team)
            let (fetchedAppIDs, fetchedProfiles) = try await (appIDs, profiles)
            return AppleDeveloperInventory(appIDs: fetchedAppIDs, profiles: fetchedProfiles)
        }
    }

    /// Completes the device registration and certificate setup deferred by the
    /// account sign-in screen before a real signing operation begins.
    private func ensureSigningReady(for target: SigningAccountSummary) async throws {
        let key = SigningSessionVault.key(
            accountIdentifier: target.accountIdentifier,
            teamIdentifier: target.teamIdentifier
        )
        let savedCredentials = try vault.load(key: key)

        if CertificateManager.shared.activeCertificate != nil,
           UserDefaults.standard.isDeviceRegistered {
            return
        }

        guard let presenter = UIApplication.shared.topViewController() else {
            throw SigningAccountError.presentationUnavailable
        }

        let handler = SideKickSignInFlowHandler(
            presentingViewController: presenter,
            appleID: savedCredentials.appleID,
            password: savedCredentials.password,
            onAuthenticationSuccess: { [weak self] in
                self?.setSignInCheckpoint("Apple ID authenticated; preparing this device for signing")
            }
        )

        let result = try await AuthManager.shared.signIn(
            presentingViewController: presenter,
            signInHandler: handler,
            skipDeviceRegistration: false,
            skipCertificateProvisioning: false,
            skipResign: true,
            skipHowTos: true
        )

        guard let appleID = AuthManager.shared.currentAppleID,
              let password = AuthManager.shared.password,
              let adsid = AuthManager.shared.adsid,
              let xcodeToken = AuthManager.shared.xcodeToken else {
            throw SigningAccountError.sessionNotAvailable
        }

        let accountIdentifier = result.team.account?.identifier ?? target.accountIdentifier
        let certificate = CertificateManager.shared.activeCertificate
        let credentials = SigningSessionCredentials(
            appleID: appleID,
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

    private func restoreAccountSession(_ account: SigningAccountSummary, activateTeam: Bool = true) async throws {
        let key = SigningSessionVault.key(
            accountIdentifier: account.accountIdentifier,
            teamIdentifier: account.teamIdentifier
        )
        let credentials = try vault.load(key: key)
        try await restoreSession(credentials, activateTeam: activateTeam)
    }

    private func restoreSession(_ credentials: SigningSessionCredentials, activateTeam: Bool = true) async throws {
        let signingCertificate = try credentials.certificateData.map {
            try CertificateManager.parse($0, password: credentials.certificatePassword)
        }

        // SideStore's authentication and certificate managers are process-global. Every
        // operation is serialized here and the previous session is restored after completion.
        await AuthManager.shared.signOut(keepCertificate: true, keepAnisetteData: true)
        AuthManager.shared.currentAppleID = credentials.appleID
        AuthManager.shared.password = credentials.password
        AuthManager.shared.adsid = credentials.adsid
        AuthManager.shared.xcodeToken = credentials.xcodeToken

        if activateTeam {
            let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
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

                let sparseRestorePatched = ProcessInfo().sparseRestorePatched
                let appLimitDisabled = UserDefaults.standard.isAppLimitDisabled
                UserDefaults.standard.activeAppsLimit = nil
                if selectedTeam.type == .free,
                   (!appLimitDisabled && sparseRestorePatched || appLimitDisabled && !sparseRestorePatched) {
                    UserDefaults.standard.activeAppsLimit = InstalledApp.freeAccountActiveAppsLimit
                }
                try context.save()
            }
        }

        if activateTeam {
            if let signingCertificate {
                try CertificateManager.shared.setActiveCertificate(signingCertificate)
            } else {
                CertificateManager.shared.clearActiveCertificate()
            }
        }
    }

    private func activeAccountSummary() async -> SigningAccountSummary? {
        guard DatabaseManager.shared.isStarted else { return nil }
        let context = DatabaseManager.shared.viewContext
        return await context.perform {
            guard let team = DatabaseManager.shared.activeTeam(in: context),
                  let account = team.account else { return nil }
            return SigningAccountSummary(
                accountIdentifier: account.identifier,
                teamIdentifier: team.identifier,
                email: account.appleID,
                teamName: team.name,
                teamType: team.type.localizedDescription,
                isFreeAccount: team.type == .free,
                hasSavedSession: true
            )
        }
    }

    private func currentSessionCredentials(for account: SigningAccountSummary?) throws -> SigningSessionCredentials {
        guard let account,
              let appleID = AuthManager.shared.currentAppleID,
              let password = AuthManager.shared.password,
              let adsid = AuthManager.shared.adsid,
              let xcodeToken = AuthManager.shared.xcodeToken else {
            throw SigningAccountError.sessionNotAvailable
        }
        let certificate = CertificateManager.shared.activeCertificate
        return SigningSessionCredentials(
            appleID: appleID,
            password: password,
            adsid: adsid,
            xcodeToken: xcodeToken,
            accountIdentifier: account.accountIdentifier,
            teamIdentifier: account.teamIdentifier,
            certificateData: certificate?.p12Data,
            certificatePassword: certificate?.password
        )
    }
}

struct AppleDeveloperInventory {
    let appIDs: [ALTAppID]
    let profiles: [ALTListedProvisioningProfile]
}

@MainActor
private final class SideKickSignInFlowHandler: SignInFlowHandler {
    private var suppliedCredentials: (String, String)?
    private var authenticationError: Error?
    private let onAuthenticationSuccess: () -> Void

    init(
        presentingViewController: UIViewController,
        appleID: String,
        password: String,
        onAuthenticationSuccess: @escaping () -> Void
    ) {
        suppliedCredentials = (appleID, password)
        self.onAuthenticationSuccess = onAuthenticationSuccess
        super.init(presentingViewController: presentingViewController)
    }

    override func credentials() async throws -> (String, String) {
        if let authenticationError { throw authenticationError }
        guard let credentials = suppliedCredentials else {
            throw SigningAccountError.credentialsUnavailable
        }
        suppliedCredentials = nil
        return credentials
    }

    override func handleSignInResult(_ result: Result<(ALTAccount, ALTAppleAPISession), Error>) async {
        switch result {
        case .success:
            onAuthenticationSuccess()
        case .failure(let error):
            authenticationError = error
        }
    }

    override func showCertificateSkipAcknowledgment() async {}

    override func showDeviceRegistrationSkipAcknowledgment() async {}
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

    func delete(key: String) throws {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SigningAccountError.keychain(status)
        }
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
    case credentialsUnavailable
    case databaseUnavailable
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .presentationUnavailable:
            return "SideKick couldn’t open Apple’s sign-in sheet. Please try again."
        case .engineBusy:
            return "SideKick can’t change accounts while an app operation is running. Wait for it to finish and try again."
        case .sessionNotAvailable:
            return "Apple ID sign-in completed without a complete session. This account was not saved."
        case .savedAccountMissing:
            return "This account or team is missing from SideKick’s local data. Sign in again to restore it."
        case .credentialsUnavailable:
            return "SideKick couldn’t retrieve the Apple ID details. Please try signing in again."
        case .databaseUnavailable:
            return "SideKick’s local database isn’t available. Restart the app and try again before signing in."
        case .keychain(let status):
            return "SideKick couldn’t securely save or load this Apple ID session (Keychain status \(status))."
        }
    }
}
