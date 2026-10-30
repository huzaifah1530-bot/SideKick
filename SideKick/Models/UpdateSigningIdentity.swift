import Foundation

/// Credential references only. Passwords and private keys remain in their existing vaults.
enum UpdateSigningIdentity: Codable, Equatable, Sendable {
    case account(identifier: String, teamIdentifier: String)
    case certificate(serialNumber: String, teamIdentifier: String)

    var teamIdentifier: String {
        switch self {
        case .account(_, let team), .certificate(_, let team): team
        }
    }
    var isValidReference: Bool {
        guard !teamIdentifier.isEmpty else { return false }
        switch self {
        case .account(let identifier, _): return !identifier.isEmpty
        case .certificate(let serial, _): return !ImportedCertificateCatalog.normalizedSerial(serial).isEmpty
        }
    }
}

struct UpdateSigningIdentityRegistry: Codable, Equatable, Sendable {
    private(set) var identities: [String: UpdateSigningIdentity] = [:]

    func identity(for installationIdentifier: String, signingTeam: String) -> UpdateSigningIdentity? {
        guard !signingTeam.isEmpty, let identity = identities[installationIdentifier.lowercased()],
              identity.teamIdentifier.caseInsensitiveCompare(signingTeam) == .orderedSame else { return nil }
        return identity
    }

    @discardableResult
    mutating func remember(_ identity: UpdateSigningIdentity, for installationIdentifier: String) -> Bool {
        guard !installationIdentifier.isEmpty, identity.isValidReference else { return false }
        identities[installationIdentifier.lowercased()] = identity
        return true
    }
}
