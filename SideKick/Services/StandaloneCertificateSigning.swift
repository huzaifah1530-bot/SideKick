import CoreData
import Foundation
import SideSign

/// Scoped by the same gate as Apple-account signing; never creates an Apple Account
/// or changes the authenticated session or its active certificate.
@MainActor
enum StandaloneCertificateSigning {
    struct Identity {
        let certificate: ALTCertificate
        let profile: ALTProvisioningProfile
        let team: ALTTeam
    }
    private(set) static var current: Identity?

    static func withCertificate<T>(_ record: ImportedCertificateRecord, operation: () async throws -> T) async throws -> T {
        guard SigningAccountOperationCoordinator.acquire() else { throw ImportedCertificateError.engineBusy }
        defer { SigningAccountOperationCoordinator.release() }
        guard !AppManager.shared.isActivelyManagingAnyApp else { throw ImportedCertificateError.engineBusy }
        let loaded = try ImportedCertificateStore.shared.signingCertificate(serialNumber: record.serialNumber)
        guard let summary = loaded.record.profile else { throw ImportedCertificateError.profileRequired(certificateName: record.name) }
        guard !summary.isExpired() else { throw ImportedCertificateError.profileExpired(summary.expirationDate) }
        guard let profile = ProfileManager.shared.getProfile(uuid: summary.uuid) else { throw ImportedCertificateError.profileUnavailable }
        guard profile.certificates.contains(where: {
            ImportedCertificateCatalog.normalizedSerial($0.serialNumber) == ImportedCertificateCatalog.normalizedSerial(record.serialNumber)
        }) else { throw ImportedCertificateError.invalidProfile }
        if let udid = Keychain.shared.deviceUDID, !udid.isEmpty, !profile.deviceIDs.isEmpty,
           !profile.deviceIDs.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }) {
            throw ImportedCertificateError.deviceNotInProfile
        }
        let team = ALTTeam(identifier: profile.teamIdentifier, name: profile.teamName, type: .individual)
        let context = DatabaseManager.shared.viewContext
        try await context.perform {
            let request = Team.fetchRequest()
            request.predicate = NSPredicate(format: "identifier == %@", profile.teamIdentifier)
            if try context.fetch(request).isEmpty {
                _ = Team(certificateTeam: team, context: context)
                try context.save()
            }
        }
        current = Identity(certificate: loaded.certificate, profile: profile, team: team)
        defer { current = nil }
        return try await operation()
    }
}
