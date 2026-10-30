import Foundation
import Observation
import SideSign

@MainActor
enum ResolvedUpdateSigningIdentity {
    case account(SigningAccountSummary)
    case certificate(ImportedCertificateRecord)

    var account: SigningAccountSummary? {
        if case .account(let account) = self { return account }
        return nil
    }
    var certificate: ImportedCertificateRecord? {
        if case .certificate(let certificate) = self { return certificate }
        return nil
    }
}

/// A per-installation update preference, separate from the app's actual signature.
@MainActor
@Observable
final class UpdateSigningIdentityStore {
    static let shared = UpdateSigningIdentityStore()
    private var registry: UpdateSigningIdentityRegistry
    private static var fileURL: URL {
        get throws { try SideKickDataDirectory.prepare().appendingPathComponent("UpdateSigningIdentities.json") }
    }

    init() {
        if let url = try? Self.fileURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(UpdateSigningIdentityRegistry.self, from: data) {
            registry = saved
        } else { registry = UpdateSigningIdentityRegistry() }
    }

    func remember(_ identity: UpdateSigningIdentity, for installationIdentifier: String) throws {
        var updated = registry
        guard updated.remember(identity, for: installationIdentifier) else { return }
        // Atomic file persistence completes before a self-update can replace this process.
        try JSONEncoder().encode(updated).write(to: Self.fileURL, options: .atomic)
        registry = updated
    }

    func resolve(for app: InstalledAppSummary, accounts: [SigningAccountSummary]) -> ResolvedUpdateSigningIdentity? {
        if let saved = registry.identity(for: app.id, signingTeam: app.teamIdentifier) {
            switch saved {
            case .account(let identifier, let team):
                return accounts.first { $0.accountIdentifier == identifier && $0.teamIdentifier == team }.map { .account($0) }
            case .certificate(let serial, let team):
                guard let certificate = ImportedCertificateStore.shared.catalog.record(matchingSerial: serial),
                      certificate.profile?.teamIdentifier == team else { return nil }
                return .certificate(certificate)
            }
        }
        if let certificate = app.importedCertificate,
           certificate.profile?.teamIdentifier == app.teamIdentifier { return .certificate(certificate) }
        if let account = accounts.first(where: {
            $0.accountIdentifier == app.accountIdentifier && $0.teamIdentifier == app.teamIdentifier
        }) { return .account(account) }
        let matches = accounts.filter { $0.teamIdentifier == app.teamIdentifier && !app.teamIdentifier.isEmpty }
        return matches.count == 1 ? .account(matches[0]) : nil
    }

    /// Adding the missing Apple login for the running copy also remembers the link.
    /// An unrelated Apple account never gets associated with a purchased certificate.
    func learnRunningAccount(_ account: SigningAccountSummary) throws {
        guard let profile = ALTApplication(fileURL: Bundle.Info.activeBundleURL)?.provisioningProfile,
              profile.teamIdentifier == account.teamIdentifier,
              registry.identity(for: Bundle.Info.activeBundleIdentifier, signingTeam: profile.teamIdentifier) == nil else { return }
        try remember(.account(identifier: account.accountIdentifier, teamIdentifier: account.teamIdentifier),
            for: Bundle.Info.activeBundleIdentifier)
    }
}
