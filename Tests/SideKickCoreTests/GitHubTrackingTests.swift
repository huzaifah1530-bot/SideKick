import Foundation
import XCTest
@testable import SideKickCore

final class GitHubTrackingTests: XCTestCase {
    private func config() -> GitHubUpdateConfiguration {
        GitHubUpdateConfiguration(bundleIdentifier: "app.TEAM", repositoryURL: "https://github.com/o/r", source: .actionsArtifact, workflowFile: "build.yml", branch: "main", assetName: "IPA", lastInstalledUpdateKey: nil)
    }
    private func target(_ observation: String = "original") -> GitHubUpdateTarget {
        GitHubUpdateTarget(id: "app.TEAM", name: "App", version: "0.8", observation: observation)
    }
    private func item(_ key: String) -> GitHubTrackedBuild {
        GitHubTrackedBuild(key: key, title: "Build", version: "0.8", assetName: "IPA", downloadURL: URL(string: "https://api.github.com/artifacts/1")!, date: nil)
    }
    func testLegacyGuessIsUnknownEvenWhenItEqualsLatest() {
        var c = config()
        c.lastInstalledUpdateKey = "actions:81:123"
        let result = GitHubTrackingPolicy.check(target: target(), configuration: c, history: [item("actions:81:123")])
        XCTAssertEqual(result.state, .unknownInstalledBuild)
        XCTAssertFalse(result.candidate?.isKnownNewer ?? true)
    }
    func testCheckingNewBuildDoesNotAdvanceInstalledReceipt() {
        var c = config()
        c.confirmInstalled("actions-v2:52:52:1:100:revision", observation: "original")
        let snapshot = c
        let result = GitHubTrackingPolicy.check(target: target(), configuration: c, history: [item("actions-v2:81:81:1:200:revision")])
        XCTAssertEqual(result.state, .updateAvailable)
        XCTAssertTrue(result.candidate?.isKnownNewer == true)
        XCTAssertEqual(c, snapshot)
    }
    func testRerunAndArtifactReplacementAreDetectedWithSameRunNumber() {
        XCTAssertEqual(GitHubTrackingPolicy.compare("actions-v2:81:81:2:201:new", to: "actions-v2:81:81:1:200:old"), .newer)
        XCTAssertEqual(GitHubTrackingPolicy.compare("actions-v2:81:81:1:201:new", to: "actions-v2:81:81:1:200:old"), .newer)
        XCTAssertEqual(GitHubTrackingPolicy.compare("actions-v2:52:52:2:201:new", to: "actions-v2:81:81:1:200:old"), .older)
    }
    func testReleaseFileReplacementAndUnorderableRevisionAreNotCurrent() {
        XCTAssertEqual(GitHubTrackingPolicy.compare("release-v2:1:201:new", to: "release-v2:1:200:old"), .newer)
        XCTAssertEqual(GitHubTrackingPolicy.compare("release-v2:1:200:changed", to: "release-v2:1:200:old"), .unknown)
    }
    func testExternalReinstallInvalidatesReceiptEvenWithSameVersionLabel() {
        var c = config()
        c.confirmInstalled("actions-v2:81:81:1:200:old", observation: "original")
        let result = GitHubTrackingPolicy.check(target: target("replacement"), configuration: c, history: [item("actions-v2:81:81:1:200:old")])
        XCTAssertEqual(result.state, .unknownInstalledBuild)
    }
    func testEmptyHistoryAndSkippedBuildAreDistinctFromCurrent() {
        var c = config()
        c.confirmInstalled("actions-v2:52:52:1:100:old", observation: "original")
        XCTAssertEqual(GitHubTrackingPolicy.check(target: target(), configuration: c, history: []).state, .noMatchingDownload)
        c.dismissedUpdateKey = "actions-v2:81:81:1:200:new"
        XCTAssertEqual(GitHubTrackingPolicy.check(target: target(), configuration: c, history: [item("actions-v2:81:81:1:200:new")]).state, .skipped)
        XCTAssertEqual(c.installedBuild?.key, "actions-v2:52:52:1:100:old")
    }
    func testSourceChangeInvalidatesReceiptButTokenChangeDoesNot() {
        var c = config()
        c.confirmInstalled("actions-v2:81:81:1:200:old", observation: "original")
        c.tokenID = "new-token"
        XCTAssertEqual(GitHubTrackingPolicy.check(target: target(), configuration: c, history: [item("actions-v2:81:81:1:200:old")]).state, .current)
        c.branch = "beta"
        XCTAssertEqual(GitHubTrackingPolicy.check(target: target(), configuration: c, history: [item("actions-v2:81:81:1:200:old")]).state, .unknownInstalledBuild)
    }
    func testCanonicalSourceIdentityAndSettingsSavePreserveConcurrentInstall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = GitHubUpdateConfigurationStore(fileURL: root.appendingPathComponent("apps.json"))
        var old = config()
        old.confirmInstalled("actions-v2:52:52:1:100:old", observation: "original")
        try await store.save(old)
        var settings = old
        settings.tokenID = "changed"
        let recorded = try await store.recordInstalled(key: "actions-v2:81:81:1:200:new", for: target(), expectedSource: old.sourceIdentity)
        XCTAssertTrue(recorded)
        try await store.saveSettings(settings, baselineKey: old.effectiveBaselineKey, baselineWasEdited: false, observation: "original")
        let saved = try await store.configuration(for: old.id)
        XCTAssertEqual(saved?.installedBuild?.key, "actions-v2:81:81:1:200:new")
        XCTAssertEqual(saved?.tokenID, "changed")
        settings.repositoryURL = "https://www.github.com/O/R.git/"
        XCTAssertEqual(settings.sourceIdentity, old.sourceIdentity)
        settings.branch = "beta"
        try await store.saveSettings(settings, baselineKey: nil, baselineWasEdited: false, observation: "original")
        let stale = try await store.recordInstalled(key: "actions-v2:90:90:1:300:new", for: target(), expectedSource: old.sourceIdentity)
        XCTAssertFalse(stale)
    }
    func testSelfUpdateRecoversAfterRestartOnlyForMatchingBinaryAndSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("apps.json")
        let store = GitHubUpdateConfigurationStore(fileURL: url)
        let c = config()
        try await store.save(c)
        try await store.prepareSelfUpdate(key: "actions-v2:81:81:1:200:new", targetID: c.id,
            expectedSource: c.sourceIdentity, executableIdentity: "new-binary")
        let restarted = GitHubUpdateConfigurationStore(fileURL: url)
        let wrong = try await restarted.recoverSelfUpdate(for: target(), executableIdentity: "old-binary")
        XCTAssertFalse(wrong)
        let before = try await restarted.configuration(for: c.id)
        XCTAssertNil(before?.installedBuild)
        let recovered = try await restarted.recoverSelfUpdate(for: target("new-observation"), executableIdentity: "new-binary")
        XCTAssertTrue(recovered)
        let saved = try await restarted.configuration(for: c.id)
        XCTAssertEqual(saved?.installedBuild?.observation, "new-observation")
        XCTAssertEqual(GitHubTrackingPolicy.check(target: target("new-observation"), configuration: saved!,
            history: [item("actions-v2:81:81:1:200:new")]).state, .current)
        try await restarted.prepareSelfUpdate(key: "other", targetID: c.id,
            expectedSource: c.sourceIdentity, executableIdentity: "another-binary")
        var changed = saved!
        changed.branch = "beta"
        try await restarted.save(changed)
        let stale = try await restarted.recoverSelfUpdate(for: target(), executableIdentity: "another-binary")
        XCTAssertFalse(stale)
    }

    func testExecutableIdentitySurvivesSigningChangesAndRejectsMalformedHeaders() {
        // 64-bit little-endian Mach-O with one LC_UUID command.
        var header = Data([0xcf, 0xfa, 0xed, 0xfe] + Array(repeating: UInt8(0), count: 28))
        header[16] = 1
        header[20] = 24
        header.append(contentsOf: [0x1b, 0, 0, 0, 24, 0, 0, 0])
        header.append(contentsOf: Array(UInt8(1)...UInt8(16)))
        let identity = GitHubExecutableIdentity.read(header)
        XCTAssertNotNil(identity)
        header.append(contentsOf: [1, 2, 3, 4]) // signing data outside the UUID
        XCTAssertEqual(GitHubExecutableIdentity.read(header), identity)
        header[40] = 99
        XCTAssertNotEqual(GitHubExecutableIdentity.read(header), identity)
        XCTAssertNil(GitHubExecutableIdentity.read(Data(header.prefix(45))))
        XCTAssertNil(GitHubExecutableIdentity.read(Data()))
    }

    func testExplicitUnknownBaselineCancelsPendingSelfUpdate() {
        var c = config()
        c.pendingSelfUpdate = GitHubPendingSelfUpdate(key: "new", sourceIdentity: c.sourceIdentity, executableIdentity: "binary")
        c.setInstalledBaseline(nil, observation: "old")
        XCTAssertNil(c.pendingSelfUpdate)
        XCTAssertNil(c.installedBuild)
    }

    func testLaterPublishedReleaseWithLowerIDIsNotSuppressedAsInstalledAhead() {
        var c = config()
        c.source = .latestRelease
        c.confirmInstalled("release-v2:200:100:old", observation: "original")
        let result = GitHubTrackingPolicy.check(target: target(), configuration: c,
            history: [item("release-v2:100:300:new")])
        XCTAssertEqual(result.state, .indeterminate)
        XCTAssertNotNil(result.candidate)
        XCTAssertEqual(GitHubTrackingPolicy.compare("release-v2:300:400:new", to: "release-v2:200:100:old"), .unknown)
    }

}
