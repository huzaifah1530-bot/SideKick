import Foundation
import XCTest
@testable import SideKickCore

final class SelfUpdateReleaseTests: XCTestCase {
    private func oldDefault() -> GitHubUpdateConfiguration {
        GitHubUpdateConfiguration(bundleIdentifier: "com.sidekick.app.TEAM", repositoryURL: "https://github.com/huzaifah1530-bot/SideKick", source: .actionsArtifact, workflowFile: "ios-build.yml", branch: "main", assetName: "SideKick-unsigned-ipa", lastInstalledUpdateKey: "actions:old", tokenID: "saved-token")
    }

    func testNewDefaultsUseReleaseIPAForInstalledVariant() {
        for vpn in [false, true] {
            let result = GitHubUpdateConfigurationStore.releaseDefault(for: "self", includesVPN: vpn)
            XCTAssertEqual(result.source, .latestRelease)
            XCTAssertEqual(result.assetName, vpn ? "SideKick+Vpn.read.release.description.ipa" : "SideKick.ipa")
            XCTAssertNil(result.effectiveBaselineKey)
        }
    }

    func testPreviousReleaseFilenameDefaultsAreCorrectedEvenAfterChannelMigration() {
        for vpn in [false, true] {
            var old = oldDefault()
            old.source = .latestRelease
            old.assetName = vpn ? "SideKick-vpn-unsigned.ipa" : "SideKick-unsigned.ipa"
            old.selfUpdateReleaseMigrationApplied = true
            let result = GitHubUpdateConfigurationStore.releaseDefault(for: old.id, includesVPN: vpn, replacing: old)
            XCTAssertEqual(result.assetName, vpn ? "SideKick+Vpn.read.release.description.ipa" : "SideKick.ipa")
            XCTAssertEqual(result.tokenID, old.tokenID)
            XCTAssertNil(result.effectiveBaselineKey)
        }
    }

    func testOldDefaultMigratesWithoutActionsReceiptsOrSkippedBuilds() {
        var old = oldDefault()
        old.confirmInstalled("actions:old", observation: "binary")
        old.dismissedUpdateKey = "actions:skip"
        old.pendingSelfUpdate = GitHubPendingSelfUpdate(key: "actions:new", sourceIdentity: old.sourceIdentity, executableIdentity: "pending")
        let result = GitHubUpdateConfigurationStore.releaseDefault(for: old.id, includesVPN: false, replacing: old)
        XCTAssertEqual(result.source, .latestRelease)
        XCTAssertEqual(result.tokenID, old.tokenID)
        XCTAssertNil(result.effectiveBaselineKey)
        XCTAssertNil(result.installedBuild)
        XCTAssertNil(result.pendingSelfUpdate)
        XCTAssertNil(result.dismissedUpdateKey)
        XCTAssertTrue(result.selfUpdateReleaseMigrationApplied == true)
    }

    func testCustomSourcesAndExplicitActionsChoiceArePreserved() {
        var custom = oldDefault()
        custom.repositoryURL = "https://github.com/other/fork"
        XCTAssertEqual(GitHubUpdateConfigurationStore.releaseDefault(for: custom.id, includesVPN: false, replacing: custom), custom)
        custom = oldDefault()
        custom.workflowFile = "nightly.yml"
        XCTAssertEqual(GitHubUpdateConfigurationStore.releaseDefault(for: custom.id, includesVPN: false, replacing: custom), custom)
        custom = oldDefault()
        custom.assetName = "custom-ipa"
        XCTAssertEqual(GitHubUpdateConfigurationStore.releaseDefault(for: custom.id, includesVPN: false, replacing: custom), custom)
        custom = oldDefault()
        custom.selfUpdateReleaseMigrationApplied = true
        XCTAssertEqual(GitHubUpdateConfigurationStore.releaseDefault(for: custom.id, includesVPN: false, replacing: custom), custom)
    }

    func testExistingSettingsDecodeWithoutMigrationMarker() throws {
        let data = try JSONEncoder().encode(oldDefault())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "selfUpdateReleaseMigrationApplied")
        let restored = try JSONDecoder().decode(GitHubUpdateConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.selfUpdateReleaseMigrationApplied)
        XCTAssertEqual(GitHubUpdateConfigurationStore.releaseDefault(for: restored.id, includesVPN: false, replacing: restored).source, .latestRelease)
    }
}
