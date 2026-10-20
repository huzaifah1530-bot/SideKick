import Foundation

/// Non-secret description of a user-imported signing certificate.
/// The PKCS#12 data and its password live in the Keychain, never here.
struct ImportedCertificateRecord: Codable, Identifiable, Equatable, Sendable {
    let serialNumber: String
    var name: String
    let issueDate: Date
    let expiryDate: Date
    let importedAt: Date
    var fileName: String

    var id: String { serialNumber }

    func isExpired(at date: Date = .now) -> Bool {
        expiryDate <= date
    }
}

enum ImportedCertificateCatalogError: LocalizedError, Equatable {
    case duplicate(name: String)
    case unknownCertificate

    var errorDescription: String? {
        switch self {
        case .duplicate(let name):
            return "“\(name)” is already imported."
        case .unknownCertificate:
            return "This certificate is no longer imported in SideKick."
        }
    }
}

/// Imported certificates plus the accounts that sign with them.
/// Accounts without an assignment keep using their Apple-issued certificate.
struct ImportedCertificateCatalog: Codable, Equatable, Sendable {
    private(set) var certificates: [ImportedCertificateRecord] = []
    /// Account key (see `accountKey`) → certificate serial number.
    private(set) var assignments: [String: String] = [:]

    static func accountKey(accountIdentifier: String, teamIdentifier: String) -> String {
        "\(accountIdentifier)|\(teamIdentifier)"
    }

    var sortedCertificates: [ImportedCertificateRecord] {
        certificates.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.expiryDate < $1.expiryDate : order == .orderedAscending
        }
    }

    func record(serialNumber: String) -> ImportedCertificateRecord? {
        certificates.first { $0.serialNumber.caseInsensitiveCompare(serialNumber) == .orderedSame }
    }

    mutating func insert(_ record: ImportedCertificateRecord) throws {
        if let existing = self.record(serialNumber: record.serialNumber) {
            throw ImportedCertificateCatalogError.duplicate(name: existing.name)
        }
        certificates.append(record)
    }

    /// Removes the certificate and returns the account keys that were using it.
    @discardableResult
    mutating func remove(serialNumber: String) -> [String] {
        certificates.removeAll { $0.serialNumber.caseInsensitiveCompare(serialNumber) == .orderedSame }
        let affected = accountKeys(using: serialNumber)
        for key in affected { assignments.removeValue(forKey: key) }
        return affected
    }

    /// Pass `nil` to return the account to its Apple-issued certificate.
    mutating func assign(serialNumber: String?, accountIdentifier: String, teamIdentifier: String) throws {
        let key = Self.accountKey(accountIdentifier: accountIdentifier, teamIdentifier: teamIdentifier)
        guard let serialNumber else {
            assignments.removeValue(forKey: key)
            return
        }
        guard let record = record(serialNumber: serialNumber) else {
            throw ImportedCertificateCatalogError.unknownCertificate
        }
        assignments[key] = record.serialNumber
    }

    func assignedRecord(accountIdentifier: String, teamIdentifier: String) -> ImportedCertificateRecord? {
        let key = Self.accountKey(accountIdentifier: accountIdentifier, teamIdentifier: teamIdentifier)
        return assignments[key].flatMap { record(serialNumber: $0) }
    }

    func accountKeys(using serialNumber: String) -> [String] {
        assignments
            .filter { $0.value.caseInsensitiveCompare(serialNumber) == .orderedSame }
            .map(\.key)
            .sorted()
    }

    /// Drops assignments for accounts that no longer exist in SideKick.
    mutating func removeAssignments(forAccountIdentifier accountIdentifier: String) {
        assignments = assignments.filter { !$0.key.hasPrefix(accountIdentifier + "|") }
    }
}
