import Foundation
import XCTest
@testable import SideKickCore

final class AnisetteConfigurationTests: XCTestCase {
    func testRejectsUnsafeServerURLs() {
        for value in ["file:///tmp/test", "https://user:password@example.com", "https://example.com/#token", "https://example.com\nInjected: yes", "http://example.com"] {
            XCTAssertThrowsError(try AnisetteConfiguration.validatedServer(value))
        }
        XCTAssertEqual(try AnisetteConfiguration.validatedServer(" https://example.com/api ").absoluteString, "https://example.com/api")
        XCTAssertNoThrow(try AnisetteConfiguration.validatedServer("http://localhost:6969"))
    }

    func testHeaderValidationPreservesFingerprintAndRejectsInjection() throws {
        XCTAssertEqual(try AnisetteConfiguration.validatedHeader(" <Windows> "), "<Windows>")
        XCTAssertThrowsError(try AnisetteConfiguration.validatedHeader("X\r\nInjected: yes"))
        XCTAssertEqual(try AnisetteConfiguration.validatedHeader(""), "")
    }

    func testBootstrapNeverOverwritesExplicitPreferences() {
        XCTAssertTrue(AnisetteConfiguration.shouldOfferWindowsDefault(persisted: [:], hasConfigFile: false, hasSavedServers: false))
        for key in ["useOnDeviceAnisette", "menuAnisetteURL", "customAnisetteClientInfo", "customAnisetteUserAgent", "customAnisetteDeviceID", "isAnisetteOfflineMode", "menuAnisetteList"] {
            XCTAssertFalse(AnisetteConfiguration.shouldOfferWindowsDefault(persisted: [key: false], hasConfigFile: false, hasSavedServers: false))
        }
        XCTAssertFalse(AnisetteConfiguration.shouldOfferWindowsDefault(persisted: [:], hasConfigFile: true, hasSavedServers: false))
        XCTAssertFalse(AnisetteConfiguration.shouldOfferWindowsDefault(persisted: [:], hasConfigFile: false, hasSavedServers: true))
    }
}
