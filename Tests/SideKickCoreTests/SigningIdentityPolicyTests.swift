import XCTest
@testable import SideKickCore

final class SigningIdentityPolicyTests: XCTestCase {
    func testDifferentSigningTeamsCannotReplaceAnInstalledApp() {
        XCTAssertNoThrow(try SigningIdentityPolicy.validateResign(installedTeam: "A", targetTeam: "A"))
        XCTAssertThrowsError(try SigningIdentityPolicy.validateResign(installedTeam: "A", targetTeam: "B"))
        XCTAssertThrowsError(try SigningIdentityPolicy.validateResign(installedTeam: nil, targetTeam: "A"))
    }
    func testOnlyMatchingAppIDsOrMatchingWildcardsCanSignTheApp() {
        XCTAssertNoThrow(try SigningIdentityPolicy.validateProfile("*", for: "com.spotify.client"))
        XCTAssertNoThrow(try SigningIdentityPolicy.validateProfile("com.spotify.*", for: "com.spotify.client"))
        XCTAssertNoThrow(try SigningIdentityPolicy.validateProfile("com.spotify.client", for: "com.spotify.client"))
        XCTAssertThrowsError(try SigningIdentityPolicy.validateProfile("com.sidekick.app", for: "com.spotify.client"))
        XCTAssertThrowsError(try SigningIdentityPolicy.validateProfile("com.spotify.*", for: "com.other.app"))
    }
}
