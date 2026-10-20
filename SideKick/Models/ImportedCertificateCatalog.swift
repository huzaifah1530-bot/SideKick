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
    /// Provisioning profile paired with this certificate. Required when the
    /// certificate belongs to a different developer team than the Apple Account.
    var profile: ImportedProfileSummary? = nil
    /// Last revocation check result. `nil` until the first check.
    var status: ImportedCertificateStatus? = nil
    var statusCheckedAt: Date? = nil

    var id: String { serialNumber }

    func isExpired(at date: Date = .now) -> Bool {
        expiryDate <= date
    }

    /// Apps stop opening at whichever expires first: the certificate or its profile.
    var effectiveExpiryDate: Date {
        min(expiryDate, profile?.expirationDate ?? expiryDate)
    }

    var isRevoked: Bool { status == .revoked }
}

enum ImportedCertificateStatus: String, Codable, Sendable {
    case valid
    case revoked
    /// The check couldn't reach Apple or got no definite answer.
    case unknown
}

struct ImportedProfileSummary: Codable, Equatable, Sendable {
    let uuid: UUID
    let name: String
    let appIdentifier: String
    let teamIdentifier: String
    let teamName: String
    let expirationDate: Date
    let deviceCount: Int
    let fileName: String

    func isExpired(at date: Date = .now) -> Bool {
        expirationDate <= date
    }
}

enum ImportedCertificateCatalogError: LocalizedError, Equatable {
    case duplicate(name: String)
    case unknownCertificate
    case noMatchingCertificate

    var errorDescription: String? {
        switch self {
        case .duplicate(let name):
            return "“\(name)” is already imported."
        case .unknownCertificate:
            return "This certificate is no longer imported in SideKick."
        case .noMatchingCertificate:
            return "This provisioning profile doesn’t include any imported certificate. Import its matching .p12 first."
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

    /// Like `record(serialNumber:)`, tolerating `0x` prefixes and leading zeros.
    func record(matchingSerial serial: String) -> ImportedCertificateRecord? {
        let target = Self.normalizedSerial(serial)
        return certificates.first { Self.normalizedSerial($0.serialNumber) == target }
    }

    mutating func insert(_ record: ImportedCertificateRecord) throws {
        if let existing = self.record(serialNumber: record.serialNumber) {
            throw ImportedCertificateCatalogError.duplicate(name: existing.name)
        }
        certificates.append(record)
    }

    /// Pairs a provisioning profile with one of the certificates it embeds.
    /// Returns the matched certificate and the profile it replaced, if any.
    @discardableResult
    mutating func attach(
        _ profile: ImportedProfileSummary,
        embeddingCertificateSerials serials: [String]
    ) throws -> (record: ImportedCertificateRecord, replaced: ImportedProfileSummary?) {
        let normalized = Set(serials.map(Self.normalizedSerial))
        guard let index = certificates.firstIndex(where: { normalized.contains(Self.normalizedSerial($0.serialNumber)) }) else {
            throw ImportedCertificateCatalogError.noMatchingCertificate
        }
        let replaced = certificates[index].profile
        certificates[index].profile = profile
        return (certificates[index], replaced?.uuid == profile.uuid ? nil : replaced)
    }

    var profileUUIDs: Set<UUID> {
        Set(certificates.compactMap { $0.profile?.uuid })
    }

    /// Serial numbers are compared the way SideStore's ProfileManager does:
    /// case-insensitive, without a 0x prefix or leading zeros.
    static func normalizedSerial(_ serial: String) -> String {
        var value = serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("0X") { value.removeFirst(2) }
        while value.hasPrefix("0") && value.count > 1 { value.removeFirst() }
        return value
    }

    mutating func setStatus(_ status: ImportedCertificateStatus, serialNumber: String, checkedAt: Date) {
        guard let index = certificates.firstIndex(where: { $0.serialNumber.caseInsensitiveCompare(serialNumber) == .orderedSame }) else { return }
        // A failed lookup must not hide a revocation seen earlier.
        if status == .unknown, certificates[index].status == .revoked { return }
        certificates[index].status = status
        certificates[index].statusCheckedAt = checkedAt
    }

    mutating func detachProfile(serialNumber: String) {
        guard let index = certificates.firstIndex(where: { $0.serialNumber.caseInsensitiveCompare(serialNumber) == .orderedSame }) else { return }
        certificates[index].profile = nil
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
