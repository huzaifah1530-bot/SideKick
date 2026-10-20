import Foundation
import XCTest
@testable import SideKickCore

final class SelfUpdateReleaseTests: XCTestCase {
    private func oldDefault() -> GitHubUpdateConfiguration {
        GitHubUpdateConfiguration(bundleIdentifier: "com.sidekick.app.TEAM", repositoryURL: "https://github.com/huzaifah1530-bot/SideKick", source: .actionsArtifact, workflowFile: "ios-build.yml", branch: "main", assetName: "SideKick-unsigned-ipa", lastInstalledUpdateKey: "actions:old", tokenID: "saved-token")
    }

    func testNewDefaultsUseReleaseIPA() {
        let result = GitHubUpdateConfigurationStore.releaseDefault(for: "self")
        XCTAssertEqual(result.source, .latestRelease)
        XCTAssertEqual(result.assetName, "SideKick.ipa")
        XCTAssertNil(result.effectiveBaselineKey)
    }

    func testPreviousReleaseFilenamesAndDiscontinuedVPNAssetsMoveToTheStandardIPA() {
        for asset in ["SideKick-unsigned.ipa"] + GitHubUpdateConfigurationStore.discontinuedVPNReleaseAssets {
            var old = oldDefault()
            old.source = .latestRelease
            old.assetName = asset
            old.selfUpdateReleaseMigrationApplied = true
            let result = GitHubUpdateConfigurationStore.releaseDefault(for: old.id, replacing: old)
            XCTAssertEqual(result.assetName, "SideKick.ipa", asset)
            XCTAssertEqual(result.tokenID, old.tokenID)
            XCTAssertNil(result.effectiveBaselineKey)
        }
    }

    func testDiscontinuedVPNActionsArtifactKeepsTheActionsChannel() {
        var old = oldDefault()
        old.assetName = "SideKick-vpn-unsigned-ipa"
        old.selfUpdateReleaseMigrationApplied = true
        let result = GitHubUpdateConfigurationStore.releaseDefault(for: old.id, replacing: old)
        XCTAssertEqual(result.source, .actionsArtifact)
        XCTAssertEqual(result.assetName, "SideKick-unsigned-ipa")
        XCTAssertEqual(result.tokenID, old.tokenID)
    }

    func testOldDefaultMigratesWithoutActionsReceiptsOrSkippedBuilds() {
        var old = oldDefault()
        old.confirmInstalled("actions:old", observation: "binary")
        old.dismissedUpdateKey = "actions:skip"
        old.pendingSelfUpdate = GitHubPendingSelfUpdate(key: "actions:new", sourceIdentity: old.sourceIdentity, executableIdentity: "pending")
        let result = GitHubUpdateConfigurationStore.releaseDefault(for: old.id, replacing: old)
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
        XCTAssertEqual(GitHubUpdateConfigurationStore.releaseDefault(for: custom.id, replacing: custom), custom)
        custom = oldDefault()
        custom.workflowFile = "nightly.yml"
        XCTAssertEqual(GitHubUpdateConfigurationStore.releaseDefault(for: custom.id, replacing: custom), custom)
        custom = oldDefault()
        custom.assetName = "custom-ipa"
        XCTAssertEqual(GitHubUpdateConfigurationStore.releaseDefault(for: custom.id, replacing: custom), custom)
        custom = oldDefault()
        custom.selfUpdateReleaseMigrationApplied = true
        XCTAssertEqual(GitHubUpdateConfigurationStore.releaseDefault(for: custom.id, replacing: custom), custom)
    }

    func testExistingSettingsDecodeWithoutMigrationMarker() throws {
        let data = try JSONEncoder().encode(oldDefault())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "selfUpdateReleaseMigrationApplied")
        let restored = try JSONDecoder().decode(GitHubUpdateConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.selfUpdateReleaseMigrationApplied)
        XCTAssertEqual(GitHubUpdateConfigurationStore.releaseDefault(for: restored.id, replacing: restored).source, .latestRelease)
    }
}
