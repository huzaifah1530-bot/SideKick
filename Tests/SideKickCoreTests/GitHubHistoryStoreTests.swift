import Foundation
import XCTest
@testable import SideKickCore

final class GitHubHistoryStoreTests: XCTestCase {
    private actor Fixture {
        var calls = 0
        func page() async throws -> GitHubHistoryPage {
            calls += 1
            let number = calls
            try await Task.sleep(nanoseconds: 20_000_000)
            return GitHubHistoryPage(builds: [GitHubTrackedBuild(
                key: "actions-v2:111:111:1:\(number):digest", title: "Build 111", version: "Build 111",
                assetName: "IPA", downloadURL: URL(string: "https://api.github.com/a")!, date: nil)], hasMore: false)
        }
    }
    private func config() -> GitHubUpdateConfiguration {
        GitHubUpdateConfiguration(bundleIdentifier: "app", repositoryURL: "https://github.com/o/r",
            source: .actionsArtifact, workflowFile: "build.yml", branch: "main", assetName: "IPA", lastInstalledUpdateKey: nil)
    }
    func testLaunchAndVersionListShareOneRequestAndExplicitReloadFetchesNewData() async throws {
        let fixture = Fixture()
        let store = GitHubHistoryStore(loader: { _, _, _ in try await fixture.page() })
        async let launch = store.page(configuration: config(), token: nil, page: 1)
        async let list = store.page(configuration: config(), token: nil, page: 1)
        let (a, b) = try await (launch, list)
        XCTAssertEqual(a.builds[0].key, b.builds[0].key)
        let reopened = try await store.page(configuration: config(), token: nil, page: 1)
        XCTAssertEqual(reopened.builds[0].key, a.builds[0].key)
        let refreshed = try await store.page(configuration: config(), token: nil, page: 1, forceRefresh: true)
        XCTAssertNotEqual(refreshed.builds[0].key, a.builds[0].key)
        let calls = await fixture.calls
        XCTAssertEqual(calls, 2)
    }
    func testExpiredCacheAndChangedCredentialsOrSourceCannotReuseOldHistory() async throws {
        let fixture = Fixture()
        let store = GitHubHistoryStore(lifetime: 0, loader: { _, _, _ in try await fixture.page() })
        _ = try await store.page(configuration: config(), token: nil, page: 1)
        _ = try await store.page(configuration: config(), token: nil, page: 1)
        let calls = await fixture.calls
        XCTAssertEqual(calls, 2)
        let partitioned = GitHubHistoryStore(loader: { _, _, _ in try await fixture.page() })
        _ = try await partitioned.page(configuration: config(), token: "a", page: 1)
        _ = try await partitioned.page(configuration: config(), token: "b", page: 1)
        var changed = config(); changed.branch = "beta"
        _ = try await partitioned.page(configuration: changed, token: "b", page: 1)
        _ = try await partitioned.page(configuration: changed, token: "b", page: 2)
        let total = await fixture.calls
        XCTAssertEqual(total, 6)
    }
    func testBuild111IsAvailableWhenBuild107IsConfirmedAndUnknownIsNeverCurrent() {
        var configuration = config()
        let target = GitHubUpdateTarget(id: "app", name: "App", version: "0.8.0", observation: "binary107")
        configuration.confirmInstalled("actions-v2:107:107:1:100:old", observation: "binary107")
        let latest = GitHubTrackedBuild(key: "actions-v2:111:111:1:101:new", title: "Build 111", version: "Build 111",
            assetName: "IPA", downloadURL: URL(string: "https://api.github.com/a")!, date: nil)
        let result = GitHubTrackingPolicy.check(target: target, configuration: configuration, history: [latest])
        XCTAssertEqual(result.state, .updateAvailable)
        XCTAssertEqual(result.latestBuild?.key, latest.key)
        configuration.installedBuild = nil
        let unknown = GitHubTrackingPolicy.check(target: target, configuration: configuration, history: [latest])
        XCTAssertEqual(unknown.state, .unknownInstalledBuild)
        XCTAssertNotNil(unknown.candidate)
    }

    func testPartialOrFailedCheckCannotClaimEverythingIsCurrent() {
        let current = GitHubCheckResult(targetID: "a", state: .current)
        let partial = GitHubUpdateSummary(configuredIDs: ["a", "b"], checks: [current], isChecking: false)
        XCTAssertEqual(partial.pendingCount, 1)
        XCTAssertEqual(partial.title, "Waiting to Check")
        let failed = GitHubCheckResult(targetID: "b", state: .failed)
        let summary = GitHubUpdateSummary(configuredIDs: ["a", "b"], checks: [current, failed], isChecking: false)
        XCTAssertEqual(summary.title, "1 App Needs Attention")
        let checking = GitHubUpdateSummary(configuredIDs: ["a"], checks: [current], isChecking: true)
        XCTAssertEqual(checking.title, "Checking for Updates")
    }

    func testFailureIsNotCachedAsSuccessfulEmptyHistory() async throws {
        actor Attempts {
            var count = 0
            func load() throws -> GitHubHistoryPage {
                count += 1
                if count == 1 { throw GitHubHistoryError.unauthorized }
                return GitHubHistoryPage(builds: [], hasMore: false)
            }
        }
        let attempts = Attempts()
        let store = GitHubHistoryStore(loader: { _, _, _ in try await attempts.load() })
        do { _ = try await store.page(configuration: config(), token: nil, page: 1); XCTFail("Must surface failure") }
        catch { XCTAssertTrue(error is GitHubHistoryError) }
        _ = try await store.page(configuration: config(), token: nil, page: 1)
        let count = await attempts.count
        XCTAssertEqual(count, 2)
    }

    func testFailedExplicitRefreshPreservesUsableSessionHistory() async throws {
        actor Attempts {
            var count = 0
            func load() throws -> GitHubHistoryPage {
                count += 1
                if count == 2 { throw GitHubHistoryError.unavailable(503) }
                return GitHubHistoryPage(builds: [], hasMore: true)
            }
        }
        let attempts = Attempts()
        let store = GitHubHistoryStore(loader: { _, _, _ in try await attempts.load() })
        _ = try await store.page(configuration: config(), token: nil, page: 1)
        do { _ = try await store.page(configuration: config(), token: nil, page: 1, forceRefresh: true); XCTFail("Must surface failure") }
        catch { XCTAssertTrue(error is GitHubHistoryError) }
        let preserved = try await store.page(configuration: config(), token: nil, page: 1)
        XCTAssertTrue(preserved.hasMore)
        let count = await attempts.count
        XCTAssertEqual(count, 2)
    }
}
