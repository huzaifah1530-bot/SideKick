import XCTest
@testable import SideKickCore

final class UpdateSigningIdentityTests: XCTestCase {
    func testSelectionSurvivesRelaunchAndIsPerInstalledCopy() throws {
        var registry = UpdateSigningIdentityRegistry()
        registry.remember(.account(identifier: "saved-account", teamIdentifier: "APPLETEAM"), for: "com.app.APPLETEAM")
        registry.remember(.certificate(serialNumber: "P12-SERIAL", teamIdentifier: "CERTTEAM"), for: "com.app.CERTTEAM")
        let relaunched = try JSONDecoder().decode(UpdateSigningIdentityRegistry.self, from: JSONEncoder().encode(registry))
        XCTAssertEqual(relaunched.identity(for: "com.app.APPLETEAM", signingTeam: "APPLETEAM"),
            .account(identifier: "saved-account", teamIdentifier: "APPLETEAM"))
        XCTAssertEqual(relaunched.identity(for: "com.app.CERTTEAM", signingTeam: "CERTTEAM"),
            .certificate(serialNumber: "P12-SERIAL", teamIdentifier: "CERTTEAM"))
        XCTAssertNil(relaunched.identity(for: "com.another.app", signingTeam: "APPLETEAM"))
    }
    func testExternalResigningToAnotherTeamDoesNotReuseTheOldSelection() {
        var registry = UpdateSigningIdentityRegistry()
        registry.remember(.certificate(serialNumber: "CERT", teamIdentifier: "OLDTEAM"), for: "com.sidekick.app")
        XCTAssertNil(registry.identity(for: "com.sidekick.app", signingTeam: "NEWTEAM"))
        XCTAssertNil(registry.identity(for: "com.sidekick.app", signingTeam: ""))
    }
    func testChangingTheChosenIdentityReplacesItsReferenceWithoutCreatingAnAppleAccount() {
        var registry = UpdateSigningIdentityRegistry()
        registry.remember(.account(identifier: "account", teamIdentifier: "TEAM"), for: "com.sidekick.app")
        registry.remember(.certificate(serialNumber: "new-cert", teamIdentifier: "TEAM"), for: "com.sidekick.app")
        XCTAssertEqual(registry.identities.count, 1)
        XCTAssertEqual(registry.identity(for: "COM.SIDEKICK.APP", signingTeam: "team"),
            .certificate(serialNumber: "new-cert", teamIdentifier: "TEAM"))
        XCTAssertFalse(registry.remember(.account(identifier: "", teamIdentifier: "TEAM"), for: "com.app"))
        XCTAssertFalse(registry.remember(.account(identifier: "account", teamIdentifier: ""), for: "com.app"))
    }
}
