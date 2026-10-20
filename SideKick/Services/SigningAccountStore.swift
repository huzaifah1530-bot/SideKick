import CoreData
import Foundation
import Observation
import Security
import SideSign
import UIKit

extension Notification.Name {
    static let sideKickSigningAccountsDidChange = Notification.Name("SideKick.SigningAccountsDidChange")
}

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

struct LiveContainerCertificateRecipient: Identifiable, Equatable, Sendable {
    let installationIdentifier: String
    let bundleIdentifier: String
    let name: String
    let accountIdentifier: String
    let accountEmail: String
    let teamIdentifier: String
    let teamName: String

    var id: String { "\(installationIdentifier)|\(accountIdentifier)|\(teamIdentifier)" }
}

@MainActor
@Observable
final class SigningAccountStore {
    private(set) var accounts: [SigningAccountSummary] = []
    private(set) var isWorking = false
    private(set) var signInCheckpoint = UserDefaults.standard.string(forKey: "sidekick.sign-in-checkpoint")

    private(set) var loadError: String?
    private let vault = SigningSessionVault()

    /// Settings changes share the signing gate, so an install cannot use half-updated identity data.
    func saveAnisetteConfiguration(server: String, clientInfo: String, userAgent: String, onDevice: Bool) async throws {
        let url = try AnisetteConfiguration.validatedServer(server)
        let client = try AnisetteConfiguration.validatedHeader(clientInfo)
        let agent = try AnisetteConfiguration.validatedHeader(userAgent)
        guard SigningAccountOperationCoordinator.acquire() else { throw SigningAccountError.engineBusy }
        defer { SigningAccountOperationCoordinator.release() }
        guard !AppManager.shared.isActivelyManagingAnyApp, !AppOffloadService.isRunning,
              !SideKickStorageCleanup.hasActiveOperations else {
            throw SigningAccountError.engineBusy
        }
        var config = await AnisetteConfigManager.shared.loadConfig()
        let configurationChanged = config.clientInfo != (client.isEmpty ? AppConstants.Anisette.defaultClientInfo : client)
            || config.userAgent != (agent.isEmpty ? AppConstants.Anisette.defaultUserAgent : agent)
            || UserDefaults.standard.useOnDeviceAnisette != onDevice
            || (!onDevice && UserDefaults.standard.menuAnisetteURL != url.absoluteString)
        config.clientInfo = client.isEmpty ? AppConstants.Anisette.defaultClientInfo : client
        config.userAgent = agent.isEmpty ? AppConstants.Anisette.defaultUserAgent : agent
        await AnisetteConfigManager.shared.saveConfig(config)
        var servers = await AnisetteServersManager.shared.loadLocalServers()
        servers.removeAll { $0.address == url.absoluteString }
        servers.insert(AnisetteServerItem(name: "Custom server", address: url.absoluteString), at: 0)
        await AnisetteServersManager.shared.saveLocalServers(servers)
        UserDefaults.standard.menuAnisetteURL = url.absoluteString
        UserDefaults.standard.useOnDeviceAnisette = onDevice
        // Keep the selected custom endpoint authoritative until the user changes it.
        UserDefaults.standard.disableAnisetteRotation = true
        UserDefaults.standard.set(true, forKey: "sidekick.anisette.defaults.v1")
        if configurationChanged {
            // Provisioning identities cannot be reused across incompatible generators.
            AnisetteConfigManager.shared.anisetteAdiBlob = nil
            AnisetteConfigManager.shared.anisetteIdentifier = nil
        }
        SideSign.AnisetteDataManager.shared.resetProvisioningCache()
        await OnDeviceAnisetteManager.shared.resetProvisioningCache()
    }

    func resetAnisetteProvisioning() async throws {
        guard SigningAccountOperationCoordinator.acquire() else { throw SigningAccountError.engineBusy }
        defer { SigningAccountOperationCoordinator.release() }
        guard !AppManager.shared.isActivelyManagingAnyApp, !AppOffloadService.isRunning,
              !SideKickStorageCleanup.hasActiveOperations else {
            throw SigningAccountError.engineBusy
        }
        // Never call signOut here: account sessions, certificates and installation records stay intact.
        AnisetteConfigManager.shared.anisetteAdiBlob = nil
        AnisetteConfigManager.shared.anisetteIdentifier = nil
        SideSign.AnisetteDataManager.shared.resetProvisioningCache()
        await OnDeviceAnisetteManager.shared.resetProvisioningCache()
    }

    private func prepareAnisetteDefaults() async {
        guard await hasNoAnisetteChoice() else { return }
        // Prefer the newest recommended server; the built-in default covers offline first runs.
        if let selection = try? await RemoteAnisetteConfigurationClient().fetchRecommended() {
            await applyAnisetteDefault(name: selection.server.name, server: selection.serverURL.absoluteString,
                clientInfo: selection.server.clientInfo, userAgent: selection.server.userAgent)
            AnisetteRemoteRecord(serverID: selection.server.id, appliedAt: .now).save()
            return
        }
        await applyAnisetteDefault(name: "Windows Anisette", server: AnisetteConfiguration.windowsServer,
            clientInfo: AnisetteConfiguration.windowsClientInfo, userAgent: AnisetteConfiguration.windowsUserAgent)
    }

    /// Applies the newest recommended Anisette server the first time SideKick opens, before
    /// the user has chosen one. Later launches and existing choices are left alone.
    func applyNewestAnisetteOnFirstLaunch() async {
        let defaults = UserDefaults.standard
        let attemptedKey = "sidekick.anisette.first-launch-newest.v1"
        guard !defaults.bool(forKey: attemptedKey) else { return }
        guard await hasNoAnisetteChoice() else {
            defaults.set(true, forKey: attemptedKey)
            return
        }
        // Offline: try again next launch. Signing in before then still tries the newest server.
        guard let selection = try? await RemoteAnisetteConfigurationClient().fetchRecommended() else { return }
        guard SigningAccountOperationCoordinator.acquire() else { return }
        defer { SigningAccountOperationCoordinator.release() }
        guard !AppManager.shared.isActivelyManagingAnyApp else { return }
        await applyAnisetteDefault(name: selection.server.name, server: selection.serverURL.absoluteString,
            clientInfo: selection.server.clientInfo, userAgent: selection.server.userAgent)
        AnisetteRemoteRecord(serverID: selection.server.id, appliedAt: .now).save()
        defaults.set(true, forKey: attemptedKey)
        debugLog("[SideKick] Applied newest Anisette server on first launch: \(selection.server.name)")
    }

    private func hasNoAnisetteChoice() async -> Bool {
        let persisted = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        let servers = await AnisetteServersManager.shared.loadLocalServers()
        return AnisetteConfiguration.shouldOfferWindowsDefault(persisted: persisted,
            hasConfigFile: AnisetteConfigManager.shared.hasConfigFile(), hasSavedServers: !servers.isEmpty)
    }

    private func applyAnisetteDefault(name: String, server: String, clientInfo: String, userAgent: String) async {
        let defaults = UserDefaults.standard
        await AnisetteServersManager.shared.saveLocalServers([AnisetteServerItem(name: name, address: server)])
        defaults.menuAnisetteURL = server
        defaults.useOnDeviceAnisette = false
        defaults.disableAnisetteRotation = true
        var config = await AnisetteConfigManager.shared.loadConfig()
        config.clientInfo = clientInfo
        config.userAgent = userAgent
        await AnisetteConfigManager.shared.saveConfig(config)
        AnisetteConfigManager.shared.anisetteAdiBlob = nil
        AnisetteConfigManager.shared.anisetteIdentifier = nil
        SideSign.AnisetteDataManager.shared.resetProvisioningCache()
        await OnDeviceAnisetteManager.shared.resetProvisioningCache()
        defaults.set(true, forKey: "sidekick.anisette.defaults.v1")
    }

    /// Old remote blobs were provisioned with a hex string where v3 expects
    /// Base64 UUID bytes. Reset that identity once under the existing signing gate.
    private func migrateRemoteAnisetteIdentifier() async {
        let defaults = UserDefaults.standard
        guard !defaults.useOnDeviceAnisette,
              !defaults.bool(forKey: "sidekick.anisette.remote-base64-identifier.v1") else { return }
        AnisetteConfigManager.shared.anisetteAdiBlob = nil
        AnisetteConfigManager.shared.anisetteIdentifier = nil
        SideSign.AnisetteDataManager.shared.resetProvisioningCache()
        await OnDeviceAnisetteManager.shared.resetProvisioningCache()
        defaults.set(true, forKey: "sidekick.anisette.remote-base64-identifier.v1")
    }

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
        try await SideKickDiagnostics.perform(.addAccount, stage: .authentication) {
            try await performAddAccount(appleID: appleID, password: password)
        }
    }

    private func performAddAccount(appleID: String, password: String) async throws {
        guard !isWorking, SigningAccountOperationCoordinator.acquire() else {
            throw SigningAccountError.engineBusy
        }
        defer { SigningAccountOperationCoordinator.release() }
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
        let previousCredentials: SigningSessionCredentials?
        if let previousAccount {
            previousCredentials = (try? currentSessionCredentials(for: previousAccount)) ?? (try? vault.load(key: SigningSessionVault.key(
                accountIdentifier: previousAccount.accountIdentifier,
                teamIdentifier: previousAccount.teamIdentifier
            )))
        } else {
            previousCredentials = nil
        }
        if let previousAccount, let previousCredentials {
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
            await prepareAnisetteDefaults()
            await migrateRemoteAnisetteIdentifier()
            result = try await AuthManager.shared.signIn(
                presentingViewController: presenter,
                signInHandler: handler,
                skipDeviceRegistration: true,
                skipCertificateProvisioning: true,
                skipHowTos: true
            )
        } catch {
            setSignInCheckpoint("Sign-in failed before the account could be saved")
            if let previousCredentials {
                do { try await restoreSession(previousCredentials) }
                catch { debugLog("[SideKick] Could not restore the previous signing session after sign-in failed: \(error.localizedDescription)") }
            }
            throw error
        }

        do {
            setSignInCheckpoint("Apple ID authenticated; saving its signing session")
            let accountIdentifier = result.team.account?.identifier ?? result.team.identifier
            let sessionKey = SigningSessionVault.key(
                accountIdentifier: accountIdentifier,
                teamIdentifier: result.team.identifier
            )
            let existingCredentials = try? vault.load(key: sessionKey)
            var certificateData = existingCredentials?.certificateData
            var certificatePassword = existingCredentials?.certificatePassword
            // A certificate moved from another SideKick copy lets this copy reuse it, instead of
            // asking Apple for a new one that could revoke the original.
            if certificateData == nil, let transferred = TransferredCertificateVault().take(key: sessionKey) {
                certificateData = transferred.p12Data
                certificatePassword = transferred.password
            }
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
            NotificationCenter.default.post(name: .sideKickSigningAccountsDidChange, object: nil)
            setSignInCheckpoint("Account saved successfully")
        } catch {
            if let id = DiagnosticsStore.operationID {
                DiagnosticsStore.shared.failure(error, operation: .addAccount, stage: .session, operationID: id)
            }
            if let previousCredentials {
                do { try await restoreSession(previousCredentials) }
                catch { debugLog("[SideKick] Could not restore the previous signing session after account setup failed: \(error.localizedDescription)") }
            }
            throw error
        }
    }

    private func setSignInCheckpoint(_ value: String) {
        if let id = DiagnosticsStore.operationID {
            switch value {
            case "Apple ID authenticated; saving its signing session":
                DiagnosticsStore.shared.record(.started, operation: DiagnosticsStore.operation, stage: .session, operationID: id)
            case "Account saved successfully":
                DiagnosticsStore.shared.record(.succeeded, operation: DiagnosticsStore.operation, stage: .session, operationID: id)
            default: break
            }
        }
        signInCheckpoint = value
        UserDefaults.standard.set(value, forKey: "sidekick.sign-in-checkpoint")
    }

    func remove(_ account: SigningAccountSummary) async throws {
        guard !isWorking, SigningAccountOperationCoordinator.acquire() else { throw SigningAccountError.engineBusy }
        defer { SigningAccountOperationCoordinator.release() }
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
            let teams = Array(savedAccount.teams)
            let teamIdentifiers = teams.map(\.identifier)
            let teamsWithInstalledApps = teams.filter { !$0.installedApps.isEmpty }
            for team in teams where team.installedApps.isEmpty {
                context.delete(team)
            }
            if teamsWithInstalledApps.isEmpty {
                context.delete(savedAccount)
            } else {
                // Keep only the nonsecret affiliation needed to reconnect installed
                // apps when this Apple account is added again. The archive tombstone
                // hides this Core Data row until successful sign-in clears it.
                savedAccount.isActiveAccount = false
                for team in teamsWithInstalledApps {
                    team.isActiveTeam = false
                }
            }
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
        ImportedCertificateStore.shared.removeAssignments(forAccountIdentifier: account.accountIdentifier)
        await reload()
        NotificationCenter.default.post(name: .sideKickSigningAccountsDidChange, object: nil)
    }

    func withAccount<T>(
        accountIdentifier: String,
        teamIdentifier: String,
        prepareForSigning: Bool = true,
        forceRefreshCertificate: Bool = false,
        useImportedCertificate: Bool = true,
        operation: () async throws -> T
    ) async throws -> T {
        guard !isWorking, SigningAccountOperationCoordinator.acquire() else { throw SigningAccountError.engineBusy }
        defer { SigningAccountOperationCoordinator.release() }
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
        var operationStarted = false
        do {
            if previous?.id != target.id || !sessionMatchesTarget {
                try await restoreAccountSession(target, activateTeam: prepareForSigning)
            }
            if prepareForSigning {
                try await ensureSigningReady(
                    for: target,
                    forceRefreshCertificate: forceRefreshCertificate,
                    useImportedCertificate: useImportedCertificate
                )
            }
            operationStarted = true
            let result = try await operation()
            if (previous?.id != target.id || !sessionMatchesTarget), let previousCredentials {
                do { try await restoreSession(previousCredentials) }
                catch { debugLog("[SideKick] Operation succeeded, but the previous signing session could not be restored: \(error.localizedDescription)") }
            }
            await reload()
            return result
        } catch {
            if (!operationStarted || previous?.id != target.id || !sessionMatchesTarget), let previousCredentials {
                do { try await restoreSession(previousCredentials) }
                catch { debugLog("[SideKick] Could not restore the previous signing session after an operation failed: \(error.localizedDescription)") }
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

    /// Return explicit installed-app/account identities for certificate export.
    /// Prefer LiveContainer's known bundle identifiers; retain a name fallback
    /// for customized builds, but let the caller present every candidate.
    func liveContainerCertificateRecipients() async throws -> [LiveContainerCertificateRecipient] {
        guard DatabaseManager.shared.isStarted else {
            throw SigningAccountError.databaseUnavailable
        }

        let context = DatabaseManager.shared.viewContext
        return try await context.perform {
            let apps = try context.fetch(InstalledApp.fetchRequest())
            let stableMatches = apps.filter {
                Self.isLiveContainerBundleIdentifier($0.bundleIdentifier) ||
                    Self.isLiveContainerBundleIdentifier($0.resignedBundleIdentifier)
            }
            let matches = stableMatches.isEmpty
                ? apps.filter { $0.name.localizedCaseInsensitiveContains("LiveContainer") }
                : stableMatches

            return matches.compactMap { app in
                guard let team = app.team, let account = team.account else { return nil }
                return LiveContainerCertificateRecipient(
                    installationIdentifier: app.resignedBundleIdentifier,
                    bundleIdentifier: app.bundleIdentifier,
                    name: app.name,
                    accountIdentifier: account.identifier,
                    accountEmail: account.appleID,
                    teamIdentifier: team.identifier,
                    teamName: team.name
                )
            }
            .sorted {
                if $0.name.localizedCaseInsensitiveCompare($1.name) != .orderedSame {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                if $0.accountEmail.localizedCaseInsensitiveCompare($1.accountEmail) != .orderedSame {
                    return $0.accountEmail.localizedCaseInsensitiveCompare($1.accountEmail) == .orderedAscending
                }
                return $0.teamIdentifier < $1.teamIdentifier
            }
        }
    }

    /// Capture the selected LiveContainer installation's saved certificate
    /// without changing SideStore's process-global active signing certificate.
    func liveContainerCertificateForExport(
        to recipient: LiveContainerCertificateRecipient
    ) async throws -> (encodedBase64Certificate: String, password: String) {
        guard SigningAccountOperationCoordinator.acquire() else { throw SigningAccountError.engineBusy }
        defer { SigningAccountOperationCoordinator.release() }
        guard DatabaseManager.shared.isStarted else {
            throw SigningAccountError.databaseUnavailable
        }

        let context = DatabaseManager.shared.viewContext
        let target = try await context.perform {
            let apps = try context.fetch(InstalledApp.fetchRequest())
            guard let liveContainer = apps.first(where: {
                $0.resignedBundleIdentifier == recipient.installationIdentifier
            }),
                  let team = liveContainer.team,
                  let account = team.account,
                  liveContainer.bundleIdentifier == recipient.bundleIdentifier,
                  account.identifier == recipient.accountIdentifier,
                  team.identifier == recipient.teamIdentifier else {
                throw SigningAccountError.savedAccountMissing
            }
            return (account.identifier, team.identifier)
        }

        let certificateData: Data
        let password: String
        if let imported = try ImportedCertificateStore.shared.assignedSigningCertificate(
            accountIdentifier: target.0,
            teamIdentifier: target.1
        ) {
            // LiveContainer needs the identity that actually signed it, so share the imported one.
            let exportPassword = imported.record.serialNumber
            certificateData = try CertificateManager.convert(imported.certificate, password: exportPassword)
            password = exportPassword
        } else {
            let credentials = try vault.load(key: SigningSessionVault.key(
                accountIdentifier: target.0,
                teamIdentifier: target.1
            ))
            guard let savedData = credentials.certificateData,
                  let savedPassword = credentials.certificatePassword else {
                throw SigningAccountError.certificateUnavailable
            }
            certificateData = savedData
            password = savedPassword
        }
        _ = try CertificateManager.parse(certificateData, password: password)
        let base64Certificate = certificateData.base64EncodedString()
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ";/?:@&=+$, ")
        guard let encodedCertificate = base64Certificate.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw SigningAccountError.certificateUnavailable
        }
        return (encodedCertificate, password)
    }

    nonisolated private static func isLiveContainerBundleIdentifier(_ value: String) -> Bool {
        let identifier = value.lowercased()
        for base in ["com.kdt.livecontainer", "com.kdt.livecontainer2", "com.kdt.livecontainer3"] {
            if identifier == base { return true }
            guard identifier.hasPrefix(base + ".") else { continue }
            let suffix = identifier.dropFirst(base.count + 1)
            if suffix.range(of: "^[a-z0-9]{10}$", options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// Completes the device registration and certificate setup deferred by the
    /// account sign-in screen before a real signing operation begins.
    private func ensureSigningReady(
        for target: SigningAccountSummary,
        forceRefreshCertificate: Bool = false,
        useImportedCertificate: Bool = true
    ) async throws {
        try await SideKickDiagnostics.perform(DiagnosticsStore.operationID == nil ? .restoreAccount : DiagnosticsStore.operation, stage: .signing) {
            try await prepareSigning(
                for: target,
                forceRefreshCertificate: forceRefreshCertificate,
                useImportedCertificate: useImportedCertificate
            )
        }
    }

    private func prepareSigning(
        for target: SigningAccountSummary,
        forceRefreshCertificate: Bool,
        useImportedCertificate: Bool
    ) async throws {
        let key = SigningSessionVault.key(
            accountIdentifier: target.accountIdentifier,
            teamIdentifier: target.teamIdentifier
        )
        let savedCredentials = try vault.load(key: key)
        let importedCertificate = try applyAssignedCertificate(
            for: target,
            savedCredentials: savedCredentials,
            useImportedCertificate: useImportedCertificate
        )

        if target.rawTeamType != nil,
           let activeCertificate = CertificateManager.shared.activeCertificate,
           UserDefaults.standard.isDeviceRegistered {
            // Imported certificates can't be renewed through Apple, so they are used as-is.
            guard forceRefreshCertificate, importedCertificate == nil else { return }
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

        await prepareAnisetteDefaults()
        let result = try await AuthManager.shared.signIn(
            presentingViewController: presenter,
            signInHandler: handler,
            skipDeviceRegistration: false,
            // With an imported certificate, register the device only; never ask Apple for a new certificate.
            skipCertificateProvisioning: importedCertificate != nil,
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
        // The vault keeps the Apple-issued certificate; an imported one stays in ImportedCertificateStore.
        let certificateData: Data?
        let certificatePassword: String?
        if let importedCertificate {
            if CertificateManager.shared.activeCertificate?.serialNumber.caseInsensitiveCompare(importedCertificate.serialNumber) != .orderedSame {
                try CertificateManager.shared.setActiveCertificate(importedCertificate)
            }
            certificateData = savedCredentials.certificateData
            certificatePassword = savedCredentials.certificatePassword
        } else {
            certificateData = CertificateManager.shared.activeCertificate?.p12Data
            certificatePassword = CertificateManager.shared.activeCertificate?.password
        }
        let credentials = SigningSessionCredentials(
            appleID: appleID,
            password: password,
            adsid: adsid,
            xcodeToken: xcodeToken,
            accountIdentifier: accountIdentifier,
            teamIdentifier: result.team.identifier,
            certificateData: certificateData,
            certificatePassword: certificatePassword
        )
        try vault.save(credentials, key: SigningSessionVault.key(
            accountIdentifier: accountIdentifier,
            teamIdentifier: result.team.identifier
        ))
        await reload()
    }

    /// Makes the account's assigned imported certificate active, or puts its Apple
    /// certificate back if an imported one was unassigned. Needs device testing.
    private func applyAssignedCertificate(
        for target: SigningAccountSummary,
        savedCredentials: SigningSessionCredentials,
        useImportedCertificate: Bool
    ) throws -> ALTCertificate? {
        let store = ImportedCertificateStore.shared
        let activeSerial = CertificateManager.shared.activeCertificate?.serialNumber
        if useImportedCertificate, let assigned = try store.assignedSigningCertificate(
            accountIdentifier: target.accountIdentifier,
            teamIdentifier: target.teamIdentifier
        ) {
            if activeSerial?.caseInsensitiveCompare(assigned.record.serialNumber) != .orderedSame {
                try CertificateManager.shared.setActiveCertificate(assigned.certificate)
            }
            return assigned.certificate
        }

        if let activeSerial, store.catalog.record(serialNumber: activeSerial) != nil {
            if let data = savedCredentials.certificateData {
                try CertificateManager.shared.setActiveCertificate(
                    CertificateManager.parse(data, password: savedCredentials.certificatePassword)
                )
            } else {
                CertificateManager.shared.clearActiveCertificate()
            }
        }
        return nil
    }

    /// Apple-issued certificate to persist for an account, ignoring an active imported one.
    private func appleCertificatePayload(for account: SigningAccountSummary) -> (data: Data?, password: String?) {
        let active = CertificateManager.shared.activeCertificate
        if let active, ImportedCertificateStore.shared.catalog.record(serialNumber: active.serialNumber) != nil {
            let saved = try? vault.load(key: SigningSessionVault.key(
                accountIdentifier: account.accountIdentifier,
                teamIdentifier: account.teamIdentifier
            ))
            return (saved?.certificateData, saved?.certificatePassword)
        }
        return (active?.p12Data, active?.password)
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
        try await SideKickDiagnostics.perform(DiagnosticsStore.operationID == nil ? .restoreAccount : DiagnosticsStore.operation, stage: .session) {
            try await applySession(credentials, activateTeam: activateTeam)
        }
    }

    private func applySession(_ credentials: SigningSessionCredentials, activateTeam: Bool) async throws {
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
            if let imported = try? ImportedCertificateStore.shared.assignedSigningCertificate(
                accountIdentifier: credentials.accountIdentifier,
                teamIdentifier: credentials.teamIdentifier
            ) {
                try CertificateManager.shared.setActiveCertificate(imported.certificate)
            } else if let signingCertificate {
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
        let certificate = appleCertificatePayload(for: account)
        return SigningSessionCredentials(
            appleID: appleID,
            password: password,
            adsid: adsid,
            xcodeToken: xcodeToken,
            accountIdentifier: account.accountIdentifier,
            teamIdentifier: account.teamIdentifier,
            certificateData: certificate.data,
            certificatePassword: certificate.password
        )
    }
}

/// AuthManager and CertificateManager hold process-global mutable state. This
/// MainActor gate coordinates separate SigningAccountStore instances and rejects
/// overlapping account/session scopes without suspending while waiting.
@MainActor
enum SigningAccountOperationCoordinator {
    private static var isOccupied = false

    static func acquire() -> Bool {
        guard !isOccupied else { return false }
        isOccupied = true
        return true
    }

    static func release() {
        isOccupied = false
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

// MARK: - Moving certificates between SideKick copies

struct TransferredAppleCertificate: Codable, Sendable {
    let accountIdentifier: String
    let teamIdentifier: String
    let email: String
    /// PKCS#12 encrypted with the password the user chose for the transfer.
    let p12Data: Data
}

extension SigningAccountStore {
    /// Apple-issued certificates of saved accounts, re-encrypted with `password` for a transfer folder.
    func transferableCertificates(password: String) throws -> [TransferredAppleCertificate] {
        try vault.all().compactMap { credentials in
            guard let data = credentials.certificateData else { return nil }
            let certificate = try CertificateManager.parse(data, password: credentials.certificatePassword)
            return TransferredAppleCertificate(
                accountIdentifier: credentials.accountIdentifier,
                teamIdentifier: credentials.teamIdentifier,
                email: credentials.appleID,
                p12Data: try CertificateManager.convert(certificate, password: password)
            )
        }
    }

    /// Keeps transferred certificates until their account signs in here. Throws if the
    /// password is wrong, so nothing is stored that can't be opened later.
    static func storeTransferredCertificates(_ items: [TransferredAppleCertificate], password: String) throws -> Int {
        let vault = TransferredCertificateVault()
        for item in items {
            _ = try CertificateManager.parse(item.p12Data, password: password)
            try vault.save(.init(p12Data: item.p12Data, password: password),
                key: SigningSessionVault.key(accountIdentifier: item.accountIdentifier, teamIdentifier: item.teamIdentifier))
        }
        return items.count
    }
}

private struct TransferredCertificateVault {
    struct Item: Codable { let p12Data: Data; let password: String }
    private let service = "com.sidekick.transferred-certificates"

    func save(_ item: Item, key: String) throws {
        let data = try JSONEncoder().encode(item)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SigningAccountError.keychain(status) }
    }

    /// Returns the item once and removes it.
    func take(key: String) -> Item? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let item = try? JSONDecoder().decode(Item.self, from: data) else { return nil }
        SecItemDelete(query as CFDictionary)
        return item
    }
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
