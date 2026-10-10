import Foundation
import XCTest
@testable import SideKickCore

final class LiveContainerTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return directory
    }

    private func bundle(_ name: String, in directory: URL, version: String = "1.0") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.guest", "CFBundleDisplayName": "Guest", "CFBundleShortVersionString": version, "CFBundleVersion": "52"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: url.appendingPathComponent("Info.plist"))
        return url
    }

    func testEmptyFolder() throws {
        let scan = try LiveContainerScanner.scan(directory: fixture(), connectionID: UUID())
        XCTAssertTrue(scan.apps.isEmpty)
        XCTAssertTrue(scan.warnings.isEmpty)
    }

    func testDuplicateBundleIDsRemainSeparateAndScanDoesNotWrite() throws {
        let directory = try fixture()
        let first = try bundle("first.app", in: directory)
        _ = try bundle("second.app", in: directory)
        let before = try Data(contentsOf: first.appendingPathComponent("Info.plist"))
        let id = UUID()
        let scan = try LiveContainerScanner.scan(directory: directory, connectionID: id)
        XCTAssertEqual(scan.apps.count, 2)
        XCTAssertEqual(Set(scan.apps.map(\.id)).count, 2)
        XCTAssertEqual(scan.apps[0].version, "1.0")
        XCTAssertEqual(scan.apps[0].build, "52")
        XCTAssertEqual(before, try Data(contentsOf: first.appendingPathComponent("Info.plist")))
        XCTAssertEqual(Set(scan.apps.map(\.id)), Set(try LiveContainerScanner.scan(directory: directory, connectionID: id).apps.map(\.id)))
    }

    func testMalformedAndPartialBundlesProduceWarnings() throws {
        let directory = try fixture()
        _ = try bundle("good.app", in: directory)
        let broken = directory.appendingPathComponent("broken.app")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: broken.appendingPathComponent("Info.plist"))
        let scan = try LiveContainerScanner.scan(directory: directory, connectionID: UUID())
        XCTAssertEqual(scan.apps.count, 1)
        XCTAssertEqual(scan.failedFolders, ["broken.app"])
        XCTAssertEqual(scan.warnings.count, 1)
    }

    func testSymlinkBundlesAreNotRead() throws {
        let directory = try fixture()
        let external = try fixture()
        let source = try bundle("external.app", in: external)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.app"), withDestinationURL: source)
        let scan = try LiveContainerScanner.scan(directory: directory, connectionID: UUID())
        XCTAssertTrue(scan.apps.isEmpty)
        XCTAssertFalse(scan.warnings.isEmpty)
    }

    func testOriginalIdentifierRecoveredWithoutModifyingGuest() throws {
        let directory = try fixture()
        let app = try bundle("original.app", in: directory)
        let info: [String: Any] = ["doUseLCBundleId": true, "LCOrignalBundleIdentifier": "test.original"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("LCAppInfo.plist"))
        XCTAssertEqual(try LiveContainerScanner.scan(directory: directory, connectionID: UUID()).apps.first?.bundleIdentifier, "test.original")
    }

    func testMissingRootThrowsRatherThanEmptySuccess() throws {
        let directory = try fixture()
        try FileManager.default.removeItem(at: directory)
        XCTAssertThrowsError(try LiveContainerScanner.scan(directory: directory, connectionID: UUID()))
    }

    func testPersistenceRepeatedRescanAndFailureRetainMetadata() async throws {
        let directory = try fixture()
        _ = try bundle("guest.app", in: directory)
        let file = directory.deletingLastPathComponent().appendingPathComponent("state.json")
        let store = LiveContainerStore(fileURL: file)
        let connection = try await store.link(directory: directory, name: "Test", scheme: "livecontainer", storageKind: .privateDocuments)
        try await store.rescan(connection.id)
        let initial = try await store.snapshot()
        XCTAssertEqual(initial.apps.count, 1)
        let restarted = LiveContainerStore(fileURL: file)
        let restored = try await restarted.snapshot()
        XCTAssertEqual(restored.apps.count, 1)
        try FileManager.default.removeItem(at: directory)
        do { try await store.rescan(connection.id); XCTFail("Missing root must fail") } catch { }
        let retained = try await store.snapshot()
        XCTAssertEqual(retained.apps.count, 1)
        XCTAssertNotNil(retained.connections.first?.lastSuccessfulScan)
        XCTAssertNotNil(retained.connections.first?.error)
    }

    func testSuccessfulMissingGuestIsMarkedUnavailable() async throws {
        let directory = try fixture()
        let app = try bundle("guest.app", in: directory)
        let store = LiveContainerStore(fileURL: directory.deletingLastPathComponent().appendingPathComponent("state.json"))
        let connection = try await store.link(directory: directory, name: "Test", scheme: "livecontainer", storageKind: .privateDocuments)
        try FileManager.default.removeItem(at: app)
        try await store.rescan(connection.id)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.apps.count, 1)
        XCTAssertFalse(snapshot.apps[0].isAvailable)
    }

    func testLaunchEncodesFolderAndRejectsInvalidSchemes() throws {
        let url = try LiveContainerLaunch.url(scheme: "livecontainer2", folder: "My App & Test.app")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "My App & Test.app")
        XCTAssertEqual(url.host, "livecontainer-launch")
        XCTAssertThrowsError(try LiveContainerLaunch.url(scheme: "https", folder: "test.app"))
        XCTAssertThrowsError(try LiveContainerLaunch.url(scheme: "bad://", folder: "test.app"))
        XCTAssertThrowsError(try LiveContainerLaunch.url(scheme: "livecontainer", folder: "../test.app"))
    }

    func testVersionChangeUpdatesExistingRecordAndRetainsSourceAssociation() async throws {
        let directory = try fixture()
        _ = try bundle("guest.app", in: directory)
        let store = LiveContainerStore(fileURL: directory.deletingLastPathComponent().appendingPathComponent("state.json"))
        let connection = try await store.link(directory: directory, name: "Test", scheme: "livecontainer", storageKind: .privateDocuments)
        let before = try await store.snapshot()
        let configs = GitHubUpdateConfigurationStore(fileURL: directory.deletingLastPathComponent().appendingPathComponent("sources.json"))
        try await configs.save(GitHubUpdateConfiguration(bundleIdentifier: before.apps[0].id, repositoryURL: "https://github.com/o/r", source: .actionsArtifact, workflowFile: "build.yml", branch: "main", assetName: "IPA", lastInstalledUpdateKey: "actions:52:1"))
        _ = try bundle("guest.app", in: directory, version: "2.0")
        try await store.rescan(connection.id)
        let after = try await store.snapshot()
        let config = try await configs.configuration(for: after.apps[0].id)
        XCTAssertEqual(after.apps.count, 1)
        XCTAssertEqual(after.apps[0].id, before.apps[0].id)
        XCTAssertEqual(after.apps[0].version, "2.0")
        XCTAssertEqual(config?.effectiveBaselineKey, "actions:52:1")
    }

    func testPartialFailureRetainsPreviousGuestAndDisconnectKeepsCatalogue() async throws {
        let directory = try fixture()
        let app = try bundle("guest.app", in: directory)
        let store = LiveContainerStore(fileURL: directory.deletingLastPathComponent().appendingPathComponent("state.json"))
        let connection = try await store.link(directory: directory, name: "Test", scheme: "livecontainer", storageKind: .privateDocuments)
        try Data("invalid".utf8).write(to: app.appendingPathComponent("Info.plist"))
        try await store.rescan(connection.id)
        let partial = try await store.snapshot()
        XCTAssertEqual(partial.apps.count, 1)
        XCTAssertEqual(partial.apps[0].name, "Guest")
        XCTAssertNotNil(partial.apps[0].warning)
        try await store.disconnect(connection.id)
        let disconnected = try await store.snapshot()
        XCTAssertEqual(disconnected.apps.count, 1)
        XCTAssertFalse(disconnected.connections[0].isConnected)
        do { try await store.rescan(connection.id); XCTFail("Disconnected scan must fail") } catch { }
        try await store.forget(connection.id)
        let forgotten = try await store.snapshot()
        XCTAssertTrue(forgotten.apps.isEmpty)
    }

    func testOversizedMetadataAndSymlinkPlistAreRejected() throws {
        let directory = try fixture()
        let app = try bundle("guest.app", in: directory)
        try Data(repeating: 0, count: 1024 * 1024 + 1).write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertEqual(try LiveContainerScanner.scan(directory: directory, connectionID: UUID()).failedFolders, ["guest.app"])
        try FileManager.default.removeItem(at: app.appendingPathComponent("Info.plist"))
        let external = try fixture()
        let source = try bundle("external.app", in: external)
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Info.plist"), withDestinationURL: source.appendingPathComponent("Info.plist"))
        XCTAssertTrue(try LiveContainerScanner.scan(directory: directory, connectionID: UUID()).apps.isEmpty)
    }

    func testRevokedBookmarkRetainsCatalogueAndRenewedBookmarkPersists() async throws {
        let directory = try fixture()
        _ = try bundle("guest.app", in: directory)
        let access = FixtureDirectoryAccess(directory: directory)
        let file = directory.deletingLastPathComponent().appendingPathComponent("state.json")
        let store = LiveContainerStore(fileURL: file, access: access)
        let connection = try await store.link(directory: directory, name: "Test", scheme: "livecontainer", storageKind: .privateDocuments)
        access.renewNextBookmark()
        try await store.rescan(connection.id)
        let renewed = try await store.snapshot()
        XCTAssertEqual(renewed.connections[0].bookmark, Data("renewed".utf8))
        access.revoke()
        do { try await store.rescan(connection.id); XCTFail("Revoked scan must fail") } catch { }
        let retained = try await store.snapshot()
        XCTAssertEqual(retained.apps.count, 1)
        XCTAssertNotNil(retained.connections[0].error)
        XCTAssertEqual(retained.connections[0].lastSuccessfulScan, renewed.connections[0].lastSuccessfulScan)
    }

    func testDisconnectWhileReconnectIsReadingDoesNotRestoreAccess() async throws {
        let directory = try fixture()
        _ = try bundle("guest.app", in: directory)
        let access = BlockingDirectoryAccess(directory: directory)
        let store = LiveContainerStore(fileURL: directory.deletingLastPathComponent().appendingPathComponent("state.json"), access: access)
        let connection = try await store.link(directory: directory, name: "Test", scheme: "livecontainer", storageKind: .privateDocuments)
        access.blockNext()
        let reconnect = Task { try await store.link(directory: directory, name: "Test", scheme: "livecontainer", storageKind: .privateDocuments, replacing: connection.id) }
        let started = await Task.detached { access.started.wait(timeout: .now() + 5) }.value
        XCTAssertEqual(started, .success)
        try await store.disconnect(connection.id)
        access.release.signal()
        _ = try? await reconnect.value
        let state = try await store.snapshot()
        XCTAssertFalse(state.connections[0].isConnected)
    }
    func testCancelledProviderScanReturnsBeforeBlockedReadAndDoesNotPublish() async throws {
        let directory = try fixture()
        _ = try bundle("guest.app", in: directory)
        let access = BlockingDirectoryAccess(directory: directory)
        let store = LiveContainerStore(fileURL: directory.deletingLastPathComponent().appendingPathComponent("state.json"), access: access)
        let connection = try await store.link(directory: directory, name: "Test", scheme: "livecontainer", storageKind: .privateDocuments)
        let before = try await store.snapshot()
        access.blockNext()
        let scan = Task { try await store.rescan(connection.id) }
        let started = await Task.detached { access.started.wait(timeout: .now() + 5) }.value
        XCTAssertEqual(started, .success)
        let cancelled = expectation(description: "Cancelled scan returns before provider releases")
        scan.cancel()
        Task {
            do { try await scan.value; XCTFail("Cancelled scan must fail") }
            catch { XCTAssertTrue(error is CancellationError) }
            cancelled.fulfill()
        }
        await fulfillment(of: [cancelled], timeout: 1)
        access.release.signal()
        let after = try await store.snapshot()
        XCTAssertEqual(after.connections[0].lastSuccessfulScan, before.connections[0].lastSuccessfulScan)
        XCTAssertNil(after.connections[0].error)
    }

}

private final class FixtureDirectoryAccess: LiveContainerDirectoryAccess, @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var revoked = false
    private var renew = false
    init(directory: URL) { self.directory = directory }
    func bookmark(for directory: URL) throws -> Data { Data("initial".utf8) }
    func scan(bookmark: Data, connectionID: UUID) throws -> (LiveContainerScan, Data?) {
        lock.lock()
        let revoked = self.revoked
        let renew = self.renew
        self.renew = false
        lock.unlock()
        if revoked { throw LiveContainerError.accessRevoked }
        return (try LiveContainerScanner.scan(directory: directory, connectionID: connectionID), renew ? Data("renewed".utf8) : nil)
    }
    func renewNextBookmark() { lock.lock(); renew = true; lock.unlock() }
    func revoke() { lock.lock(); revoked = true; lock.unlock() }
}

private final class BlockingDirectoryAccess: LiveContainerDirectoryAccess, @unchecked Sendable {
    let directory: URL
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var block = false
    init(directory: URL) { self.directory = directory }
    func blockNext() { lock.lock(); block = true; lock.unlock() }
    func bookmark(for directory: URL) throws -> Data { Data("bookmark".utf8) }
    func scan(bookmark: Data, connectionID: UUID) throws -> (LiveContainerScan, Data?) {
        lock.lock(); let blocking = block; block = false; lock.unlock()
        if blocking { started.signal(); _ = release.wait(timeout: .now() + 10) }
        return (try LiveContainerScanner.scan(directory: directory, connectionID: connectionID), nil)
    }
}
