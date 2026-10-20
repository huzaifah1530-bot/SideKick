import Foundation
import Observation
import Security
import SideSign

enum ImportedCertificateError: LocalizedError, Equatable {
    case unreadableFile
    case publicCertificateOnly
    case unsupportedFormat
    case passwordRequired
    case incorrectPassword
    case missingPrivateKey
    case expired(Date)
    case secretUnavailable
    case keychain(OSStatus)
    case invalidProfile
    case profileExpired(Date)
    case profileRequired(certificateName: String)
    case profileUnavailable
    case profileInUse(appName: String, appIdentifier: String)
    case updateCertificateMismatch(certificateName: String)
    case revoked(certificateName: String)
    case deviceNotInProfile

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "SideKick couldn’t read this file."
        case .publicCertificateOnly:
            return "This file has only the public certificate. Export the certificate with its private key as a .p12 file and try again."
        case .unsupportedFormat:
            return "This isn’t a .p12 certificate file."
        case .passwordRequired:
            return "This certificate is protected by a password."
        case .incorrectPassword:
            return "The password is incorrect."
        case .missingPrivateKey:
            return "This .p12 file doesn’t contain a private key, so it can’t sign apps."
        case .expired(let date):
            return "This certificate expired on \(date.formatted(date: .abbreviated, time: .omitted))."
        case .secretUnavailable:
            return "SideKick couldn’t load this certificate from the Keychain. Delete it and import it again."
        case .keychain(let status):
            return "Keychain error \(status)."
        case .invalidProfile:
            return "This isn’t a valid .mobileprovision file."
        case .profileExpired(let date):
            return "This provisioning profile expired on \(date.formatted(date: .abbreviated, time: .omitted))."
        case .profileRequired(let name):
            return "“\(name)” belongs to a different developer team, so it needs its provisioning profile. In Settings → Advanced → Certificates, import the matching .mobileprovision file."
        case .profileUnavailable:
            return "The provisioning profile for this certificate is missing. Import the .mobileprovision file again."
        case .updateCertificateMismatch(let name):
            return "This app is signed with “\(name)”, but its account now uses a different certificate. Updating would move it to another team and lose its data. Switch the account back to “\(name)” to update it, or re-sign it first."
        case .deviceNotInProfile:
            return "This provisioning profile doesn’t include this iPhone, so apps signed with it won’t install. Ask your certificate provider for a profile registered to this device."
        case .revoked(let name):
            return "Apple has revoked “\(name)”. Apps signed with it won’t open. Import a new certificate from your provider."
        case .profileInUse(let appName, let appIdentifier):
            return "This certificate’s profile covers only one app ID (\(appIdentifier)), and “\(appName)” already uses it. Installing would replace that app. Delete it first, or ask your certificate provider for a wildcard profile."
        }
    }
}

/// Owns user-imported signing certificates. Secrets are stored in the Keychain
/// (this device only); `ImportedCertificateCatalog` holds non-secret metadata.
@MainActor
@Observable
final class ImportedCertificateStore {
    static let shared = ImportedCertificateStore()

    private(set) var catalog = ImportedCertificateCatalog()
    private(set) var loadError: String?
    private let vault = ImportedCertificateVault()

    init() {
        reload()
    }

    var certificates: [ImportedCertificateRecord] { catalog.sortedCertificates }

    func reload() {
        do {
            catalog = try ImportedCertificateCatalogFile.load()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Reads and validates a PKCS#12 file. Throws `.passwordRequired` so the UI can ask once.
    @discardableResult
    func importCertificate(from url: URL, password: String?) throws -> ImportedCertificateRecord {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw ImportedCertificateError.unreadableFile }
        return try importCertificate(data: data, fileName: url.lastPathComponent, password: password)
    }

    @discardableResult
    func importCertificate(data: Data, fileName: String, password: String?) throws -> ImportedCertificateRecord {
        guard data.isPKCS12 else {
            if ALTX509Certificate(data: data) != nil { throw ImportedCertificateError.publicCertificateOnly }
            throw ImportedCertificateError.unsupportedFormat
        }

        let normalizedPassword = password.flatMap { $0.isEmpty ? nil : $0 }
        let certificate: ALTCertificate
        do {
            certificate = try CertificateManager.parse(data, password: normalizedPassword)
        } catch ALTCertificateError.missingPrivateKey {
            throw ImportedCertificateError.missingPrivateKey
        } catch ALTCertificateError.decryptionFailed {
            throw normalizedPassword == nil ? ImportedCertificateError.passwordRequired : ImportedCertificateError.incorrectPassword
        }

        let x509 = certificate.x509
        guard x509.expiryDate > .now else { throw ImportedCertificateError.expired(x509.expiryDate) }

        let record = ImportedCertificateRecord(
            serialNumber: certificate.serialNumber,
            name: certificate.name,
            issueDate: x509.creationDate,
            expiryDate: x509.expiryDate,
            importedAt: .now,
            fileName: fileName
        )
        var updated = catalog
        try updated.insert(record)
        try vault.save(ImportedCertificateSecret(p12Data: data, password: normalizedPassword), serialNumber: record.serialNumber)
        do {
            try ImportedCertificateCatalogFile.save(updated)
        } catch {
            try? vault.delete(serialNumber: record.serialNumber)
            throw error
        }
        catalog = updated
        Task { await checkStatuses() }
        return record
    }

    /// Imports a .mobileprovision and pairs it with the imported certificate it embeds.
    @discardableResult
    func importProfile(from url: URL) throws -> ImportedCertificateRecord {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw ImportedCertificateError.unreadableFile }
        return try importProfile(data: data, fileName: url.lastPathComponent)
    }

    @discardableResult
    func importProfile(data: Data, fileName: String) throws -> ImportedCertificateRecord {
        guard let profile = try? ALTProvisioningProfile(data: data) else { throw ImportedCertificateError.invalidProfile }
        guard profile.expirationDate > .now else { throw ImportedCertificateError.profileExpired(profile.expirationDate) }
        // SideStore caches this iPhone's UDID once pairing has worked. Skip the check before that.
        if let udid = Keychain.shared.deviceUDID, !udid.isEmpty, !profile.deviceIDs.isEmpty,
           !profile.deviceIDs.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }) {
            throw ImportedCertificateError.deviceNotInProfile
        }

        let summary = ImportedProfileSummary(
            uuid: profile.uuid,
            name: profile.name,
            appIdentifier: profile.bundleIdentifier,
            teamIdentifier: profile.teamIdentifier,
            teamName: profile.teamName,
            expirationDate: profile.expirationDate,
            deviceCount: profile.deviceIDs.count,
            fileName: fileName
        )
        var updated = catalog
        let result = try updated.attach(summary, embeddingCertificateSerials: profile.certificates.map(\.serialNumber))
        // SideStore's ProfileManager owns profile files so its signing pipeline can use them.
        _ = try ProfileManager.shared.importProfile(data: data)
        try ImportedCertificateCatalogFile.save(updated)
        catalog = updated
        if let replaced = result.replaced { ProfileManager.shared.deleteProfile(uuid: replaced.uuid) }
        return result.record
    }

    func removeProfile(from record: ImportedCertificateRecord) throws {
        guard let profile = record.profile else { return }
        var updated = catalog
        updated.detachProfile(serialNumber: record.serialNumber)
        try ImportedCertificateCatalogFile.save(updated)
        catalog = updated
        ProfileManager.shared.deleteProfile(uuid: profile.uuid)
    }

    func delete(_ record: ImportedCertificateRecord) throws {
        let record = catalog.record(serialNumber: record.serialNumber) ?? record
        var updated = catalog
        updated.remove(serialNumber: record.serialNumber)
        try ImportedCertificateCatalogFile.save(updated)
        catalog = updated
        if let profile = record.profile { ProfileManager.shared.deleteProfile(uuid: profile.uuid) }
        try vault.delete(serialNumber: record.serialNumber)
    }

    /// Points SideStore's per-app profile assignment at the imported profile for this
    /// account, or clears an assignment SideKick made earlier. SideStore's
    /// UpdateAppCertificateOperation reads it before profiles are fetched from Apple,
    /// which is what lets another team's certificate sign. Needs device testing.
    func prepareProfileAssignment(
        bundleIdentifiers: [String],
        accountIdentifier: String,
        teamIdentifier: String,
        useImportedCertificate: Bool = true
    ) throws {
        let owned = catalog.profileUUIDs
        let clearOwnedAssignments = {
            for bundleIdentifier in Set(bundleIdentifiers) {
                if let current = ProfileManager.shared.getAssignedProfile(for: bundleIdentifier), owned.contains(current.uuid) {
                    ProfileManager.shared.setAssignedProfile(nil, for: bundleIdentifier)
                }
            }
        }

        guard useImportedCertificate,
              let assigned = try assignedSigningCertificate(accountIdentifier: accountIdentifier, teamIdentifier: teamIdentifier) else {
            clearOwnedAssignments()
            return
        }
        guard let summary = assigned.record.profile else {
            clearOwnedAssignments()
            let isOtherTeam = assigned.certificate.data.map { data in
                let details = parseCertificate(derData: data)
                return !details.subject.contains(teamIdentifier) && !details.issuer.contains(teamIdentifier)
            } ?? true
            if isOtherTeam { throw ImportedCertificateError.profileRequired(certificateName: assigned.record.name) }
            return
        }
        guard !summary.isExpired() else { throw ImportedCertificateError.profileExpired(summary.expirationDate) }
        guard ProfileManager.shared.getProfile(uuid: summary.uuid) != nil else { throw ImportedCertificateError.profileUnavailable }
        for bundleIdentifier in Set(bundleIdentifiers) {
            ProfileManager.shared.assignProfile(uuid: summary.uuid, for: bundleIdentifier)
        }
    }

    func assign(_ record: ImportedCertificateRecord?, to account: SigningAccountSummary) throws {
        var updated = catalog
        try updated.assign(
            serialNumber: record?.serialNumber,
            accountIdentifier: account.accountIdentifier,
            teamIdentifier: account.teamIdentifier
        )
        try ImportedCertificateCatalogFile.save(updated)
        catalog = updated
    }

    private(set) var isCheckingStatus = false

    /// Asks Apple (OCSP/CRL through Security.framework) whether each certificate is revoked.
    func checkStatuses() async {
        guard !isCheckingStatus else { return }
        isCheckingStatus = true
        defer { isCheckingStatus = false }
        for record in catalog.certificates {
            let status: ImportedCertificateStatus
            do {
                let secret = try vault.load(serialNumber: record.serialNumber)
                let x509 = try CertificateManager.parse(secret.p12Data, password: secret.password).x509
                try await OCSPValidator.validate(x509)
                status = .valid
            } catch OCSPValidationError.revoked {
                status = .revoked
            } catch {
                debugLog("[SideKick] Certificate status check for \(record.serialNumber) was inconclusive: \(error.localizedDescription)")
                status = .unknown
            }
            var updated = catalog
            updated.setStatus(status, serialNumber: record.serialNumber, checkedAt: .now)
            guard updated != catalog else { continue }
            do {
                try ImportedCertificateCatalogFile.save(updated)
                catalog = updated
            } catch {
                debugLog("[SideKick] Could not save certificate status: \(error.localizedDescription)")
            }
        }
    }

    func removeAssignments(forAccountIdentifier accountIdentifier: String) {
        var updated = catalog
        updated.removeAssignments(forAccountIdentifier: accountIdentifier)
        guard updated != catalog else { return }
        do {
            try ImportedCertificateCatalogFile.save(updated)
            catalog = updated
        } catch {
            debugLog("[SideKick] Could not clear imported certificate assignments: \(error.localizedDescription)")
        }
    }

    func assignedRecord(accountIdentifier: String, teamIdentifier: String) -> ImportedCertificateRecord? {
        catalog.assignedRecord(accountIdentifier: accountIdentifier, teamIdentifier: teamIdentifier)
    }

    func assignedAccountKeys(for record: ImportedCertificateRecord) -> [String] {
        catalog.accountKeys(using: record.serialNumber)
    }

    /// The signing identity assigned to an account, or `nil` when it uses Apple's certificate.
    func assignedSigningCertificate(accountIdentifier: String, teamIdentifier: String) throws -> (record: ImportedCertificateRecord, certificate: ALTCertificate, p12Data: Data, password: String?)? {
        guard let record = assignedRecord(accountIdentifier: accountIdentifier, teamIdentifier: teamIdentifier) else {
            return nil
        }
        guard !record.isExpired() else { throw ImportedCertificateError.expired(record.expiryDate) }
        guard !record.isRevoked else { throw ImportedCertificateError.revoked(certificateName: record.name) }
        let secret = try vault.load(serialNumber: record.serialNumber)
        do {
            let certificate = try CertificateManager.parse(secret.p12Data, password: secret.password)
            return (record, certificate, secret.p12Data, secret.password)
        } catch {
            throw ImportedCertificateError.secretUnavailable
        }
    }
}

private struct ImportedCertificateSecret: Codable {
    let p12Data: Data
    let password: String?
}

private struct ImportedCertificateVault {
    private let service = "com.sidekick.imported-certificates"

    func save(_ secret: ImportedCertificateSecret, serialNumber: String) throws {
        let data = try JSONEncoder().encode(secret)
        var query = baseQuery(serialNumber: serialNumber)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ImportedCertificateError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw ImportedCertificateError.keychain(status)
        }
    }

    func load(serialNumber: String) throws -> ImportedCertificateSecret {
        var query = baseQuery(serialNumber: serialNumber)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let secret = try? JSONDecoder().decode(ImportedCertificateSecret.self, from: data) else {
            throw ImportedCertificateError.secretUnavailable
        }
        return secret
    }

    func delete(serialNumber: String) throws {
        let status = SecItemDelete(baseQuery(serialNumber: serialNumber) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ImportedCertificateError.keychain(status)
        }
    }

    private func baseQuery(serialNumber: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serialNumber.lowercased()
        ]
    }
}

private enum ImportedCertificateCatalogFile {
    private static var url: URL {
        get throws {
            guard let directory = SideKickDataDirectory.url else { throw CocoaError(.fileNoSuchFile) }
            return directory.appendingPathComponent("ImportedCertificates.json")
        }
    }

    static func load() throws -> ImportedCertificateCatalog {
        let url = try Self.url
        guard FileManager.default.fileExists(atPath: url.path) else { return ImportedCertificateCatalog() }
        return try JSONDecoder().decode(ImportedCertificateCatalog.self, from: Data(contentsOf: url))
    }

    static func save(_ catalog: ImportedCertificateCatalog) throws {
        try JSONEncoder().encode(catalog).write(
            to: Self.url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}
