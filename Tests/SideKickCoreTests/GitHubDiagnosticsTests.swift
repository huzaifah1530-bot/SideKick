import Foundation
import XCTest
@testable import SideKickCore

final class GitHubDiagnosticsTests: XCTestCase {
    func testDiagnosticsPersistBoundedHistoryAndClearIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("checks.json")
        let store = GitHubDiagnosticsStore(fileURL: file, limit: 2)
        await store.record(.scanStarted, count: 3)
        await store.record(.checkFinished, appName: "Example", state: .updateAvailable)
        await store.record(.scanFinished, count: 1)
        let restored = GitHubDiagnosticsStore(fileURL: file, limit: 2)
        let snapshot = await restored.snapshot()
        XCTAssertEqual(snapshot.entries.map(\.event), [.scanFinished, .checkFinished])
        await restored.clear()
        let afterClear = await GitHubDiagnosticsStore(fileURL: file).snapshot()
        XCTAssertTrue(afterClear.entries.isEmpty)
    }

    func testRepositoryLoggingDropsCredentialsQueriesAndFragments() async throws {
        let store = GitHubDiagnosticsStore()
        await store.record(.requestFinished, repository: "https://user:secret@github.com/Owner/Repo/actions?token=secret#secret", authenticated: true, httpStatus: 403)
        let snapshot = await store.snapshot()
        let text = GitHubDiagnosticsStore.export(snapshot.entries)
        XCTAssertTrue(text.contains("owner/repo"))
        XCTAssertTrue(text.contains("403"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("user:"))
        XCTAssertTrue(text.contains("Token supplied"))
        XCTAssertEqual(GitHubDiagnosticsStore.Failure.classify(GitHubHistoryError.unauthorized), .authorization)
        XCTAssertEqual(GitHubDiagnosticsStore.Failure.classify(NSError(domain: "secret", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret-token"])), .unknown)
    }

    func testUntrustedRepositoryAndTokenLikeNamesCannotLeakIntoExport() async {
        let store = GitHubDiagnosticsStore()
        await store.record(.checkStarted, appName: "ghp_abcdefghijklmnopqrstuvwxyz1234567890", repository: "https://other.example/private?token=secret")
        let snapshot = await store.snapshot()
        let text = GitHubDiagnosticsStore.export(snapshot.entries)
        XCTAssertFalse(text.contains("ghp_"))
        XCTAssertFalse(text.contains("other.example"))
        XCTAssertFalse(text.contains("secret"))
    }
}
