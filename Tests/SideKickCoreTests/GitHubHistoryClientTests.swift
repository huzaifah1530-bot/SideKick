import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SideKickCore

final class GitHubHistoryClientTests: XCTestCase {
    private func config(_ source: GitHubUpdateSource = .actionsArtifact, asset: String = "IPA", branch: String = "main") -> GitHubUpdateConfiguration {
        GitHubUpdateConfiguration(bundleIdentifier: "app", repositoryURL: "https://github.com/o/r", source: source, workflowFile: "build.yml", branch: branch, assetName: asset, lastInstalledUpdateKey: nil)
    }
    func testReplacedReleaseAssetHasDistinctIdentityEvenWithSameTagAndFileName() async throws {
        func reader(_ id: Int) -> GitHubHistoryClient {
            GitHubHistoryClient { request in
                let value: [[String: Any]] = [["id": 1, "tag_name": "v0.8", "draft": false, "published_at": "2026-10-01T00:00:00Z", "assets": [["id": id, "name": "app.ipa", "url": "https://api.github.com/asset/1", "digest": "sha256:abc", "updated_at": "2026-10-01T00:00:00Z"]]]]
                return (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let first = try await reader(100).page(configuration: config(.latestRelease, asset: "app.ipa"), token: nil, page: 1)
        let second = try await reader(101).page(configuration: config(.latestRelease, asset: "app.ipa"), token: nil, page: 1)
        XCTAssertNotEqual(first.builds.first?.key, second.builds.first?.key)
        XCTAssertEqual(second.builds.first?.version, "v0.8")
    }
    func testAmbiguousAssetsRequireSpecificSelection() async throws {
        let reader = GitHubHistoryClient { request in
            let value: [[String: Any]] = [["id": 1, "tag_name": "v1", "assets": [["id": 1, "name": "phone.ipa", "url": "https://api.github.com/a"], ["id": 2, "name": "tablet.ipa", "url": "https://api.github.com/b"]]]]
            return (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await reader.page(configuration: config(.latestRelease, asset: ""), token: nil, page: 1); XCTFail("Must not select the first arbitrary IPA") }
        catch { XCTAssertTrue(error is GitHubHistoryError) }
    }
    func testRunWithoutDownloadIsNotReportedAsCurrentAndArtifactPagesAreRead() async throws {
        let reader = GitHubHistoryClient { request in
            let url = request.url!
            let value: [String: Any]
            if url.path.hasSuffix("/runs") {
                XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "branch" })
                value = ["workflow_runs": [["id": 83, "run_number": 83, "run_attempt": 1, "head_branch": "beta", "conclusion": "success"], ["id": 82, "run_number": 82, "run_attempt": 2, "head_branch": "main", "conclusion": "success"]]]
            } else if url.path.contains("/83/") { value = ["artifacts": []] }
            else if url.query?.contains("page=2") == true {
                value = ["artifacts": [["id": 200, "name": "IPA", "expired": false, "archive_download_url": "https://api.github.com/artifacts/200/zip"]]]
            } else {
                value = ["artifacts": (1...100).map { ["id": $0, "name": "other", "expired": false, "archive_download_url": "https://api.github.com/artifacts/other/zip"] }]
            }
            return (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let page = try await reader.page(configuration: config(branch: "*"), token: nil, page: 1)
        XCTAssertEqual(page.builds.count, 1)
        XCTAssertTrue(page.newerBuildHasNoDownload)
        XCTAssertTrue(page.builds[0].key.hasPrefix("actions-v2:82:82:2:200:"))
    }
    func testTokenFailureDoesNotProduceAnEmptySuccessfulHistory() async throws {
        let reader = GitHubHistoryClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await reader.page(configuration: config(), token: "fake-token", page: 1); XCTFail("Failed HTTP must throw") }
        catch { XCTAssertTrue(error is GitHubHistoryError) }
    }
}
