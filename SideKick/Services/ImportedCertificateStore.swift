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
        return record
    }

    func delete(_ record: ImportedCertificateRecord) throws {
        var updated = catalog
        updated.remove(serialNumber: record.serialNumber)
        try ImportedCertificateCatalogFile.save(updated)
        catalog = updated
        try vault.delete(serialNumber: record.serialNumber)
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
