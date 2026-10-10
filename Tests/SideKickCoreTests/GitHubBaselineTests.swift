import Foundation
import XCTest
@testable import SideKickCore

final class GitHubBaselineTests: XCTestCase {
    func testManualOriginalBaselineWinsOverNewerInstalledBuild() {
        var config = GitHubUpdateConfiguration(bundleIdentifier: "app", repositoryURL: "https://github.com/o/r", source: .actionsArtifact, workflowFile: "build.yml", branch: "main", assetName: "IPA", baselineUpdateKey: "actions:52:52", lastInstalledUpdateKey: "actions:81:81")
        config.setInstalledBaseline("actions:52:52")
        XCTAssertEqual(config.effectiveBaselineKey, "actions:52:52")
        XCTAssertNil(config.lastInstalledUpdateKey)
    }

    func testExactBuildOrderingWithExpiredBaselineAndUnchangedVersion() {
        XCTAssertTrue(GitHubBuildComparison.isNewer("actions:81:123", than: "actions:52:321", historyKeys: ["actions:81:123"]))
        XCTAssertFalse(GitHubBuildComparison.isNewer("actions:81:123", than: "actions:81:123", historyKeys: ["actions:81:123"]))
        XCTAssertFalse(GitHubBuildComparison.isNewer("actions:52:321", than: "actions:81:123", historyKeys: []))
        XCTAssertFalse(GitHubBuildComparison.isNewer("release:999:v1:IPA", than: "actions:52:321", historyKeys: []))
    }

    func testGuestSourcePersistsSeparatelyFromNormalApp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = GitHubUpdateConfigurationStore(fileURL: root.appendingPathComponent("apps.json"))
        let guestID = LiveContainerGuest.identifier(connectionID: UUID(), folder: "guest.app")
        for id in ["test.guest", guestID] {
            try await store.save(GitHubUpdateConfiguration(bundleIdentifier: id, repositoryURL: "https://github.com/o/r", source: .latestRelease, workflowFile: "", branch: "", assetName: "", lastInstalledUpdateKey: "release:1:v1:app.ipa"))
        }
        let all = try await store.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(guestID.hasPrefix("livecontainer:"))
        let restored = try await store.configuration(for: guestID)
        XCTAssertNotNil(restored)
    }
    func testInstalledSourceMigrationOnlyWhenUnambiguous() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = GitHubUpdateConfigurationStore(fileURL: root.appendingPathComponent("apps.json"))
        for id in ["one", "ambiguous"] {
            try await store.save(GitHubUpdateConfiguration(bundleIdentifier: id, repositoryURL: "https://github.com/o/r", source: .latestRelease, workflowFile: "", branch: "", assetName: "", baselineUpdateKey: "release:1:v1:app.ipa", tokenID: "saved-token"))
        }
        try await store.migrateInstalledIdentifiers(["one": ["one.TEAM"], "ambiguous": ["ambiguous.A", "ambiguous.B"]])
        let restored = try await store.configuration(for: "one.TEAM")
        XCTAssertEqual(restored?.baselineUpdateKey, "release:1:v1:app.ipa")
        XCTAssertEqual(restored?.tokenID, "saved-token")
        let old = try await store.configuration(for: "one")
        XCTAssertNil(old)
        let ambiguous = try await store.configuration(for: "ambiguous")
        XCTAssertNotNil(ambiguous)
        let other = try await store.configuration(for: "ambiguous.B")
        XCTAssertNil(other)
        try await store.migrateInstalledIdentifiers(["one": ["one.TEAM", "one.OTHER"]])
        let unchanged = try await store.configuration(for: "one.TEAM")
        XCTAssertEqual(unchanged, restored)
    }

    func testQueuesForTwoInstallationsRetainTheirOwnFilesAndMetadata() throws {
        var first = ImportedIPA(bundleIdentifier: "product", name: "App", version: "1", fileName: "a.ipa", sourceBookmarkData: nil, sourceURLString: nil, importedAt: Date(timeIntervalSince1970: 1), iconData: nil)
        first.queuedForInstalledAppID = "product.A"
        var second = ImportedIPA(bundleIdentifier: "product", name: "App", version: "2", fileName: "b.ipa", sourceBookmarkData: nil, sourceURLString: nil, importedAt: Date(timeIntervalSince1970: 2), iconData: nil)
        second.queuedForInstalledAppID = "product.B"
        var entries = IPAImportIndex.replacing(second, in: [first])
        XCTAssertEqual(Set(entries.compactMap(\.fileName)), ["a.ipa", "b.ipa"])
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
        first.githubUpdateKey = "new-build"
        entries = IPAImportIndex.replacing(first, in: entries)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.githubUpdateKey, "new-build")
        let restored = try JSONDecoder().decode([ImportedIPA].self, from: JSONEncoder().encode(entries))
        XCTAssertEqual(Set(restored.compactMap(\.queuedForInstalledAppID)), ["product.A", "product.B"])
    }

}
