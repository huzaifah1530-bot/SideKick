import Foundation
import XCTest
@testable import SideKickCore

final class LiveContainerImportTests: XCTestCase {
    func testConfirmedGuestRetainsSourceAcrossRestartAndDoesNotConfigureNativeApp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sources.json")
        let store = GitHubUpdateConfigurationStore(fileURL: file)
        let connection = connection()
        let guest = guest(connection)
        let app = ipa()
        let encoded = try JSONEncoder().encode(app)
        let reloaded = try JSONDecoder().decode(ImportedIPA.self, from: encoded)
        let applied = try await store.recordLiveContainerImport(reloaded, guest: guest, connection: connection)
        XCTAssertTrue(applied)
        let restarted = GitHubUpdateConfigurationStore(fileURL: file)
        let saved = try await restarted.configuration(for: guest.id)
        XCTAssertEqual(saved?.sourceIdentity, app.githubSourceIdentity)
        XCTAssertEqual(saved?.tokenID, "named-token")
        XCTAssertEqual(saved?.workflowFile, "build.yml")
        XCTAssertEqual(saved?.branch, "main")
        XCTAssertEqual(saved?.assetName, "App-IPA")
        XCTAssertEqual(saved?.installedBuild?.key, app.githubUpdateKey)
        XCTAssertEqual(saved?.installedBuild?.observation, guest.updateTarget.observation)
        let native = try await restarted.configuration(for: app.bundleIdentifier)
        XCTAssertNil(native)
    }

    func testRejectsWrongGuestSnapshotAndChangedExistingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubUpdateConfigurationStore(fileURL: root.appendingPathComponent("sources.json"))
        let connection = connection()
        var guest = guest(connection)
        let app = ipa()
        guest.build = "older"
        XCTAssertFalse(LiveContainerImportPolicy.matches(app, guest: guest, connection: connection))
        guest.build = "12"
        var withIdentity = app
        withIdentity.executableIdentity = "new-binary"
        guest.executableIdentity = "old-binary"
        XCTAssertFalse(LiveContainerImportPolicy.matches(withIdentity, guest: guest, connection: connection))
        guest.executableIdentity = nil
        var snapshot = connection
        snapshot.storageKind = .snapshot
        XCTAssertFalse(LiveContainerImportPolicy.matches(app, guest: guest, connection: snapshot))
        var other = app.githubImportConfiguration!
        other.bundleIdentifier = guest.id
        other.repositoryURL = "https://github.com/other/repo"
        try await store.save(other)
        let applied = try await store.recordLiveContainerImport(app, guest: guest, connection: connection)
        XCTAssertFalse(applied)
        let unchanged = try await store.configuration(for: guest.id)
        XCTAssertEqual(unchanged?.repositoryURL, other.repositoryURL)
        XCTAssertNil(unchanged?.installedBuild)
    }

    func testGitHubHandoffAutomaticallyLinksSourceAndVerifiesActualBinaryAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sources.json")
        let store = GitHubUpdateConfigurationStore(fileURL: file)
        let connection = connection()
        var guest = guest(connection)
        guest.executableIdentity = "binary-uuid"
        var app = ipa()
        app.executableIdentity = "binary-uuid"
        app.liveContainerHandoffRequested = true
        let retained = try JSONDecoder().decode(ImportedIPA.self, from: JSONEncoder().encode(app))
        var catalogue = LiveContainerState()
        catalogue.connections = [connection]
        catalogue.apps = [guest]
        // Downloading alone must not mark a guest installed.
        try await store.reconcileLiveContainerImports([ipa()], catalogue: catalogue)
        let before = try await store.configuration(for: guest.id)
        XCTAssertNil(before)
        try await store.reconcileLiveContainerImports([retained], catalogue: catalogue)
        let restarted = GitHubUpdateConfigurationStore(fileURL: file)
        let saved = try await restarted.configuration(for: guest.id)
        XCTAssertEqual(saved?.sourceIdentity, app.githubSourceIdentity)
        XCTAssertEqual(saved?.installedBuild?.key, app.githubUpdateKey)
        XCTAssertEqual(saved?.tokenID, "named-token")
        try await restarted.reconcileLiveContainerImports([retained], catalogue: catalogue)
        let unchanged = try await restarted.configuration(for: guest.id)
        XCTAssertEqual(saved, unchanged)
    }

    func testVersionMatchWithoutBinaryProofSavesSourceWithoutGuessingInstalledBuild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubUpdateConfigurationStore(fileURL: root.appendingPathComponent("sources.json"))
        let connection = connection()
        var catalogue = LiveContainerState()
        catalogue.connections = [connection]
        catalogue.apps = [guest(connection)]
        var app = ipa()
        app.liveContainerHandoffRequested = true
        try await store.reconcileLiveContainerImports([app], catalogue: catalogue)
        let saved = try await store.configuration(for: catalogue.apps[0].id)
        XCTAssertEqual(saved?.sourceIdentity, app.githubSourceIdentity)
        XCTAssertNil(saved?.installedBuild)
        XCTAssertNil(saved?.effectiveBaselineKey)
    }

    func testAmbiguousConnectionsAndSnapshotsAreNeverLinkedAutomatically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubUpdateConfigurationStore(fileURL: root.appendingPathComponent("sources.json"))
        let first = connection(), second = connection()
        var catalogue = LiveContainerState()
        catalogue.connections = [first, second]
        catalogue.apps = [guest(first), guest(second)]
        var app = ipa()
        app.liveContainerHandoffRequested = true
        let linked = try await store.reconcileLiveContainerImports([app], catalogue: catalogue)
        XCTAssertTrue(linked.isEmpty)
        let sources = try await store.all()
        XCTAssertTrue(sources.isEmpty)
        catalogue.connections = [first]
        catalogue.connections[0].storageKind = .snapshot
        catalogue.apps = [guest(first)]
        let snapshots = try await store.reconcileLiveContainerImports([app], catalogue: catalogue)
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testScannerReadsBinaryIdentityForBothScanModesAndRejectsExecutableLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Applications")
        let bundle = directory.appendingPathComponent("App.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.app", "CFBundleExecutable": "App", "CFBundleShortVersionString": "1", "CFBundleVersion": "12"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        var binary = Data(repeating: 0, count: 56)
        binary.replaceSubrange(0..<4, with: [0xcf, 0xfa, 0xed, 0xfe])
        binary[16] = 1; binary[20] = 24; binary[32] = 0x1b; binary[36] = 24
        binary.replaceSubrange(40..<56, with: Array(repeating: UInt8(7), count: 16))
        let executable = bundle.appendingPathComponent("App")
        try binary.write(to: executable)
        let id = UUID(), expected = String(repeating: "07", count: 16)
        XCTAssertEqual(try LiveContainerScanner.scan(directory: directory, connectionID: id).apps.first?.executableIdentity, expected)
        XCTAssertEqual(try LiveContainerScanner.scan(directory: directory, connectionID: id, folder: "App.app").executableIdentity, expected)
        let external = root.appendingPathComponent("external")
        try binary.write(to: external)
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: external)
        XCTAssertNil(try LiveContainerScanner.scan(directory: directory, connectionID: id, folder: "App.app").executableIdentity)
    }

    private func connection() -> LiveContainerConnection {
        LiveContainerConnection(id: UUID(), name: "LiveContainer", scheme: "livecontainer", storageKind: .privateDocuments, bookmark: Data([1]))
    }
    private func guest(_ connection: LiveContainerConnection) -> LiveContainerGuest {
        LiveContainerGuest(connectionID: connection.id, folder: "App.app", name: "App", bundleIdentifier: "test.app", version: "1", build: "12", lastSeen: .now, observation: "guest-observation")
    }
    private func ipa() -> ImportedIPA {
        let source = GitHubUpdateConfiguration(bundleIdentifier: "test.app", repositoryURL: "https://github.com/owner/repo", source: .actionsArtifact, workflowFile: "build.yml", branch: "main", assetName: "App-IPA", lastInstalledUpdateKey: nil, tokenID: "named-token")
        return ImportedIPA(bundleIdentifier: "test.app", name: "App", version: "1", fileName: "app.ipa", sourceBookmarkData: nil, sourceURLString: nil, importedAt: .now, iconData: nil, buildVersion: "12", githubUpdateKey: "actions-v2:12:12:1:123:revision", githubSourceIdentity: source.sourceIdentity, githubRepositoryURL: source.repositoryURL, githubImportConfiguration: source)
    }
}
