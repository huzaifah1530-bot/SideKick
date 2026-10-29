import XCTest
@testable import SideKickCore

final class SigningIdentityPolicyTests: XCTestCase {
    func testDifferentSigningTeamsCannotReplaceAnInstalledApp() {
        XCTAssertNoThrow(try SigningIdentityPolicy.validateResign(installedTeam: "A", targetTeam: "A"))
        XCTAssertThrowsError(try SigningIdentityPolicy.validateResign(installedTeam: "A", targetTeam: "B"))
        XCTAssertThrowsError(try SigningIdentityPolicy.validateResign(installedTeam: nil, targetTeam: "A"))
    }
}
