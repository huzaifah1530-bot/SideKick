import XCTest
@testable import SideKickCore

final class SigningRecoveryTests: XCTestCase {
    func testSuccessfulInstallClearsOnlyItsOwnTrackingAndPreservesTransferMetadata() throws {
        let suite = "SideKick-recovery-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("recoveryNeeded", forKey: "SideKick.offload.app")
        defaults.set(true, forKey: "SideKick.binary-recovery.app")
        defaults.set(true, forKey: "SideKick.hidden-offloaded.app")
        defaults.set("offloaded", forKey: "SideKick.offload.other")
        defaults.set(try JSONSerialization.data(withJSONObject: ["state": "recoveryNeeded", "backupPath": "retained-backup"]),
            forKey: "SideKick.transfer.app")
        AppInstallationState.recordSuccessfulInstall(identifier: "app", defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "SideKick.offload.app"))
        XCTAssertNil(defaults.object(forKey: "SideKick.binary-recovery.app"))
        XCTAssertNil(defaults.object(forKey: "SideKick.hidden-offloaded.app"))
        XCTAssertEqual(defaults.string(forKey: "SideKick.offload.other"), "offloaded")
        let transfer = try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "SideKick.transfer.app"))) as! [String: String]
        XCTAssertEqual(transfer["state"], "active")
        XCTAssertEqual(transfer["backupPath"], "retained-backup")
    }

    func testExportRequiresTheInstalledSignerInsteadOfAnAssignedOrLatestCertificate() throws {
        XCTAssertNoThrow(try CertificateExportPolicy.validate(candidate: "ABCD", recorded: "abcd", cachedSigner: "ABCD", profileSerials: []))
        XCTAssertThrowsError(try CertificateExportPolicy.validate(candidate: "NEW", recorded: "OLD", cachedSigner: "OLD", profileSerials: ["NEW", "OLD"]))
        XCTAssertThrowsError(try CertificateExportPolicy.validate(candidate: "NEW", recorded: nil, cachedSigner: "OLD", profileSerials: ["NEW"]))
        XCTAssertThrowsError(try CertificateExportPolicy.validate(candidate: "NEW", recorded: nil, cachedSigner: nil, profileSerials: ["NEW", "OTHER"]))
        XCTAssertNoThrow(try CertificateExportPolicy.validate(candidate: "ONLY", recorded: nil, cachedSigner: nil, profileSerials: ["ONLY"]))
        XCTAssertThrowsError(try CertificateExportPolicy.validate(candidate: "RECORDED", recorded: "RECORDED", cachedSigner: "OTHER", profileSerials: []))
    }
}
