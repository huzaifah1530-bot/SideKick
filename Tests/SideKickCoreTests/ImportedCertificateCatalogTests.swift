import XCTest
@testable import SideKickCore

final class ImportedCertificateCatalogTests: XCTestCase {
    private func record(_ serial: String, name: String = "Distribution", expiresIn interval: TimeInterval = 86_400) -> ImportedCertificateRecord {
        ImportedCertificateRecord(
            serialNumber: serial,
            name: name,
            issueDate: Date(timeIntervalSince1970: 0),
            expiryDate: Date().addingTimeInterval(interval),
            importedAt: Date(),
            fileName: "\(name).p12"
        )
    }

    func testRejectsDuplicateSerialIgnoringCase() throws {
        var catalog = ImportedCertificateCatalog()
        try catalog.insert(record("ABC123"))
        XCTAssertThrowsError(try catalog.insert(record("abc123", name: "Copy"))) { error in
            XCTAssertEqual(error as? ImportedCertificateCatalogError, .duplicate(name: "Distribution"))
        }
        XCTAssertEqual(catalog.certificates.count, 1)
    }

    func testAssignmentIsPerAccountAndTeam() throws {
        var catalog = ImportedCertificateCatalog()
        try catalog.insert(record("AAA"))
        try catalog.assign(serialNumber: "aaa", accountIdentifier: "acct", teamIdentifier: "TEAM1")

        XCTAssertEqual(catalog.assignedRecord(accountIdentifier: "acct", teamIdentifier: "TEAM1")?.serialNumber, "AAA")
        XCTAssertNil(catalog.assignedRecord(accountIdentifier: "acct", teamIdentifier: "TEAM2"))

        try catalog.assign(serialNumber: nil, accountIdentifier: "acct", teamIdentifier: "TEAM1")
        XCTAssertNil(catalog.assignedRecord(accountIdentifier: "acct", teamIdentifier: "TEAM1"))
    }

    func testAssigningUnknownCertificateFails() {
        var catalog = ImportedCertificateCatalog()
        XCTAssertThrowsError(try catalog.assign(serialNumber: "missing", accountIdentifier: "a", teamIdentifier: "t")) { error in
            XCTAssertEqual(error as? ImportedCertificateCatalogError, .unknownCertificate)
        }
    }

    func testRemovingCertificateClearsItsAssignments() throws {
        var catalog = ImportedCertificateCatalog()
        try catalog.insert(record("AAA"))
        try catalog.insert(record("BBB", name: "Other"))
        try catalog.assign(serialNumber: "AAA", accountIdentifier: "one", teamIdentifier: "T")
        try catalog.assign(serialNumber: "AAA", accountIdentifier: "two", teamIdentifier: "T")
        try catalog.assign(serialNumber: "BBB", accountIdentifier: "three", teamIdentifier: "T")

        let affected = catalog.remove(serialNumber: "aaa")

        XCTAssertEqual(affected, ["one|T", "two|T"])
        XCTAssertEqual(catalog.certificates.map(\.serialNumber), ["BBB"])
        XCTAssertEqual(catalog.accountKeys(using: "BBB"), ["three|T"])
    }

    func testRemovingAccountDropsOnlyItsAssignments() throws {
        var catalog = ImportedCertificateCatalog()
        try catalog.insert(record("AAA"))
        try catalog.assign(serialNumber: "AAA", accountIdentifier: "one", teamIdentifier: "T1")
        try catalog.assign(serialNumber: "AAA", accountIdentifier: "one", teamIdentifier: "T2")
        try catalog.assign(serialNumber: "AAA", accountIdentifier: "onetwo", teamIdentifier: "T1")

        catalog.removeAssignments(forAccountIdentifier: "one")

        XCTAssertEqual(catalog.accountKeys(using: "AAA"), ["onetwo|T1"])
    }

    func testExpiryAndRoundTrip() throws {
        XCTAssertTrue(record("X", expiresIn: -1).isExpired())
        XCTAssertFalse(record("Y").isExpired())

        var catalog = ImportedCertificateCatalog()
        try catalog.insert(record("Y", name: "b"))
        try catalog.insert(record("Z", name: "A"))
        try catalog.assign(serialNumber: "Y", accountIdentifier: "acct", teamIdentifier: "T")
        let decoded = try JSONDecoder().decode(ImportedCertificateCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(decoded, catalog)
        XCTAssertEqual(decoded.sortedCertificates.map(\.name), ["A", "b"])
    }
}
