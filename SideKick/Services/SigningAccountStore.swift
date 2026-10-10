import CoreData
import Foundation
import Observation
import Security
import SideSign
import UIKit

struct SigningAccountSummary: Identifiable, Equatable, Codable, Sendable {
    let accountIdentifier: String
    let teamIdentifier: String
    let email: String
    let teamName: String
    let teamType: String
    let isFreeAccount: Bool
    let hasSavedSession: Bool

    var rawTeamType: Int? = nil

    var id: String { "\(accountIdentifier)|\(teamIdentifier)" }
}

@MainActor
@Observable
final class SigningAccountStore {
    private(set) var accounts: [SigningAccountSummary] = []
    private(set) var isWorking = false
    private(set) var signInCheckpoint = UserDefaults.standard.string(forKey: "sidekick.sign-in-checkpoint")

    private(set) var loadError: String?
    private let vault = SigningSessionVault()

    func reload() async {
        do {
            var archive = try SigningAccountArchive.load()
            var summaries = Dictionary(archive.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // The Keychain can outlive database metadata after a migration. Never
            // put passwords or tokens in the account catalogue.
            let sessions = try vault.all()
            for session in sessions where !archive.removedAccountIdentifiers.contains(session.accountIdentifier) {
                let summary = SigningAccountSummary(accountIdentifier: session.accountIdentifier,
                    teamIdentifier: session.teamIdentifier, email: session.appleID,
                    teamName: "", teamType: "Sign in to restore team details",
                    isFreeAccount: false, hasSavedSession: true)
                if summaries[summary.id] == nil { summaries[summary.id] = summary }
            }
            if DatabaseManager.shared.isStarted {
                let context = DatabaseManager.shared.viewContext
                let restored = Array(summaries.values)
                let removedIdentifiers = archive.removedAccountIdentifiers
                let records = try await context.perform {
                    var savedAccounts = try context.fetch(Account.fetchRequest())
                    // Recreate known team metadata without creating an active session.
                    for summary in restored where !removedIdentifiers.contains(summary.accountIdentifier) {
                        guard let rawTeamType = summary.rawTeamType else { continue }
                        let account: Account
                        if let existing = savedAccounts.first(where: { $0.identifier == summary.accountIdentifier }) {
                            account = existing
                        } else {
                            account = Account(ALTAccount(appleID: summary.email, identifier: summary.accountIdentifier), context: context)
                            savedAccounts.append(account)
                        }
                        if !account.teams.contains(where: { $0.identifier == summary.teamIdentifier }) {
                            let team = ALTTeam(identifier: summary.teamIdentifier, name: summary.teamName,
                                type: ALTTeamType(rawValue: rawTeamType) ?? .unknown)
                            _ = Team(team, account: account, context: context)
                        }
                    }
                    if context.hasChanges { try context.save() }
                    return savedAccounts.flatMap { account in
                        account.teams.map { team in
                            var summary = SigningAccountSummary(accountIdentifier: account.identifier,
                                teamIdentifier: team.identifier, email: account.appleID, teamName: team.name,
                                teamType: team.type.localizedDescription, isFreeAccount: team.type == .free,
                                hasSavedSession: false)
                            summary.rawTeamType = team.type.rawValue
                            return summary
                        }
                    }
                }
                for record in records where !archive.removedAccountIdentifiers.contains(record.accountIdentifier) {
                    summaries[record.id] = record
                }
            }
            let sessionKeys = Set(sessions.map { SigningSessionVault.key(accountIdentifier: $0.accountIdentifier, teamIdentifier: $0.teamIdentifier) })
            accounts = summaries.values.map { summary in
                SigningAccountSummary(accountIdentifier: summary.accountIdentifier,
                    teamIdentifier: summary.teamIdentifier, email: summary.email, teamName: summary.teamName,
                    teamType: summary.teamType, isFreeAccount: summary.isFreeAccount,
                    hasSavedSession: sessionKeys.contains(SigningSessionVault.key(accountIdentifier: summary.accountIdentifier, teamIdentifier: summary.teamIdentifier)),
                    rawTeamType: summary.rawTeamType)
            }.sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
            archive.accounts = accounts
            try archive.save()
            loadError = nil
        } catch {
            // A locked Keychain or transient Core Data error must not erase the list.
            if accounts.isEmpty, let archive = try? SigningAccountArchive.load() {
                accounts = archive.accounts.map {
                    SigningAccountSummary(accountIdentifier: $0.accountIdentifier,
                        teamIdentifier: $0.teamIdentifier, email: $0.email, teamName: $0.teamName,
                        teamType: $0.teamType, isFreeAccount: $0.isFreeAccount, hasSavedSession: false,
                        rawTeamType: $0.rawTeamType)
                }
            }
            loadError = "Saved accounts couldn’t be fully loaded. Unlock your device and try again."
            debugLog("[SideKick] Failed to load signing accounts: \(error.localizedDescription)")
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
        var archive = try SigningAccountArchive.load()
        archive.removedAccountIdentifiers.remove(accountIdentifier)
        try archive.save()
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
            guard let savedAccount = try context.fetch(request).first else { return [account.teamIdentifier] }
            let teamIdentifiers = savedAccount.teams.map(\.identifier)
            context.delete(savedAccount)
            try context.save()
            return teamIdentifiers
        }

        var archive = try SigningAccountArchive.load()
        archive.removedAccountIdentifiers.insert(account.accountIdentifier)
        let archivedTeams = archive.accounts.filter { $0.accountIdentifier == account.accountIdentifier }.map(\.teamIdentifier)
        archive.accounts.removeAll { $0.accountIdentifier == account.accountIdentifier }
        try archive.save()
        accounts.removeAll { $0.accountIdentifier == account.accountIdentifier }

        if wasActive {
            await AuthManager.shared.signOut(keepCertificate: false, keepAnisetteData: true)
        }
        for teamIdentifier in Set(teamIdentifiers + archivedTeams) {
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
        forceRefreshCertificate: Bool = false,
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
                try await ensureSigningReady(for: target, forceRefreshCertificate: forceRefreshCertificate)
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

        let team = try await developerTeam(for: account)

        return try await withAccount(
            accountIdentifier: account.accountIdentifier,
            teamIdentifier: account.teamIdentifier,
            prepareForSigning: false
        ) {
            async let appIDs = DeveloperPortalProxy.shared.fetchAppIDs(team: team)
            async let profiles = DeveloperPortalProxy.shared.listProvisioningProfiles(team: team)
            async let certificates = DeveloperPortalProxy.shared.fetchCertificates(team: team)
            let (fetchedAppIDs, fetchedProfiles, fetchedCertificates) = try await (appIDs, profiles, certificates)
            return AppleDeveloperInventory(
                appIDs: fetchedAppIDs,
                profiles: fetchedProfiles,
                certificates: fetchedCertificates
            )
        }
    }

    func revokeDeveloperCertificate(
        _ certificate: ALTX509Certificate,
        for account: SigningAccountSummary
    ) async throws -> Bool {
        let team = try await developerTeam(for: account)
        return try await withAccount(
            accountIdentifier: account.accountIdentifier,
            teamIdentifier: account.teamIdentifier,
            prepareForSigning: false
        ) {
            try await DeveloperPortalProxy.shared.revokeCertificate(certificate, team: team)
        }
    }

    func fetchDeveloperCertificates(for account: SigningAccountSummary) async throws -> [ALTX509Certificate] {
        let team = try await developerTeam(for: account)
        return try await withAccount(
            accountIdentifier: account.accountIdentifier,
            teamIdentifier: account.teamIdentifier,
            prepareForSigning: false
        ) {
            try await DeveloperPortalProxy.shared.fetchCertificates(team: team)
        }
    }

    private func developerTeam(for account: SigningAccountSummary) async throws -> ALTTeam {
        guard DatabaseManager.shared.isStarted else {
            throw SigningAccountError.databaseUnavailable
        }

        let accountIdentifier = account.accountIdentifier
        let teamIdentifier = account.teamIdentifier
        let context = DatabaseManager.shared.viewContext
        return try await context.perform {
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
    }

    /// Restore the certificate associated with LiveContainer before the SideStore
    /// deep-link exporter reads its process-global active certificate.
    func prepareCertificateForLiveContainerExport() async throws {
        guard DatabaseManager.shared.isStarted else {
            throw SigningAccountError.databaseUnavailable
        }

        let context = DatabaseManager.shared.viewContext
        let target = try await context.perform {
            let apps = try context.fetch(InstalledApp.fetchRequest())
            let liveContainer = apps.first {
                $0.name.localizedCaseInsensitiveContains("LiveContainer") ||
                    $0.bundleIdentifier.localizedCaseInsensitiveContains("livecontainer") ||
                    $0.resignedBundleIdentifier.localizedCaseInsensitiveContains("livecontainer")
            }
            guard let liveContainer,
                  let team = liveContainer.team,
                  let account = team.account else {
                throw SigningAccountError.savedAccountMissing
            }
            return (account.identifier, team.identifier)
        }

        let credentials = try vault.load(key: SigningSessionVault.key(
            accountIdentifier: target.0,
            teamIdentifier: target.1
        ))
        guard let certificateData = credentials.certificateData else {
            throw SigningAccountError.certificateUnavailable
        }
        let certificate = try CertificateManager.parse(certificateData, password: credentials.certificatePassword)
        try CertificateManager.shared.setActiveCertificate(certificate)
    }

    /// Completes the device registration and certificate setup deferred by the
    /// account sign-in screen before a real signing operation begins.
    private func ensureSigningReady(for target: SigningAccountSummary, forceRefreshCertificate: Bool = false) async throws {
        let key = SigningSessionVault.key(
            accountIdentifier: target.accountIdentifier,
            teamIdentifier: target.teamIdentifier
        )
        let savedCredentials = try vault.load(key: key)

        if target.rawTeamType != nil,
           let activeCertificate = CertificateManager.shared.activeCertificate,
           UserDefaults.standard.isDeviceRegistered {
            guard forceRefreshCertificate else { return }
            let team = try await developerTeam(for: target)
            let portalCertificates = try await DeveloperPortalProxy.shared.fetchCertificates(team: team)
            if portalCertificates.contains(where: { $0.serialNumber.caseInsensitiveCompare(activeCertificate.serialNumber) == .orderedSame }) {
                return
            }

            debugLog("[SideKick] Active certificate is missing from the Apple Developer Portal; renewing it before the re-sign operation.")
            CertificateManager.shared.clearActiveCertificate()
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
        try await restoreSession(credentials, activateTeam: activateTeam && account.rawTeamType != nil)
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
    let certificates: [ALTX509Certificate]
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

    func all() throws -> [SigningSessionCredentials] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw SigningAccountError.keychain(status) }
        let data = (result as? [Data]) ?? (result as? Data).map { [$0] } ?? []
        return try data.map { try JSONDecoder().decode(SigningSessionCredentials.self, from: $0) }
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

/// Non-secret metadata only. Authentication remains in the Keychain.
private struct SigningAccountArchive: Codable {
    var accounts: [SigningAccountSummary] = []
    var removedAccountIdentifiers: Set<String> = []

    private static var url: URL {
        get throws {
            guard let directory = SideKickDataDirectory.url else { throw SigningAccountError.databaseUnavailable }
            return directory.appendingPathComponent("SigningAccounts.json")
        }
    }

    static func load() throws -> Self {
        let url = try Self.url
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func save() throws {
        try JSONEncoder().encode(self).write(to: Self.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

private enum SigningAccountError: LocalizedError {
    case presentationUnavailable
    case engineBusy
    case sessionNotAvailable
    case savedAccountMissing
    case credentialsUnavailable
    case certificateUnavailable
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
        case .certificateUnavailable:
            return "SideKick has no saved signing certificate for the account used by LiveContainer. Refresh LiveContainer in SideKick, then import the certificate again."
        case .databaseUnavailable:
            return "SideKick’s local database isn’t available. Restart the app and try again before signing in."
        case .keychain(let status):
            return "SideKick couldn’t securely save or load this Apple ID session (Keychain status \(status))."
        }
    }
}
