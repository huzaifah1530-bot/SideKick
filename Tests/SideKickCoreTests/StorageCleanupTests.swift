import Foundation
import XCTest
@testable import SideKickCore

final class StorageCleanupTests: XCTestCase {
    func testRealPipelineMarkersAndOriginalBundleNameAreRemovableAtIdle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("sidekick-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Spotify.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("1234".utf8).write(to: folder.appendingPathComponent(".sidekick-process"))
        try Data().write(to: folder.appendingPathComponent("App.ipa"))
        XCTAssertTrue(InstallTemporaryDirectory.isDisposable(folder, inside: root))
        try Data().write(to: folder.appendingPathComponent("recovery.json"))
        XCTAssertFalse(InstallTemporaryDirectory.isDisposable(folder, inside: root))
    }

    func testLegacyInstallFoldersCanBeClearedButUnknownFoldersAndBackupsCannot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("4A0D73B3-2DC3-43BC-ABE3-4F18FE5202BB-7991-0000017E49003AED")
        let app = folder.appendingPathComponent("App.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "app.example"], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertTrue(InstallTemporaryDirectory.isDisposable(folder, inside: root))
        let unknown = root.appendingPathComponent("user-files")
        try FileManager.default.copyItem(at: folder, to: unknown)
        XCTAssertFalse(InstallTemporaryDirectory.isDisposable(unknown, inside: root))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        XCTAssertFalse(InstallTemporaryDirectory.isDisposable(folder, inside: root))
    }

    func testPipelineClassificationRejectsLinksAndRecognizesInterruptedEmptyStage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("sidekick-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("1234".utf8).write(to: folder.appendingPathComponent(".sidekick-process"))
        XCTAssertTrue(InstallTemporaryDirectory.isDisposable(folder, inside: root))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("App.app"), withDestinationURL: root)
        XCTAssertFalse(InstallTemporaryDirectory.isDisposable(folder, inside: root))
    }
    func testPipelineNameAloneDoesNotAuthorizeRemovalAndCompletionSurvivesRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("sidekick-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: folder.appendingPathComponent("App.ipa"))
        XCTAssertFalse(InstallTemporaryDirectory.isDisposable(folder, inside: root))
        try Data("invalid".utf8).write(to: folder.appendingPathComponent(".sidekick-process"))
        XCTAssertFalse(InstallTemporaryDirectory.isDisposable(folder, inside: root))
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".sidekick-process"))
        try Data("SideKick completed staging v1\n".utf8).write(to: folder.appendingPathComponent(".sidekick-disposable"))
        XCTAssertTrue(InstallTemporaryDirectory.isDisposable(folder, inside: root))
        XCTAssertFalse(InstallTemporaryDirectory.isDisposable(folder, inside: root.deletingLastPathComponent()))
    }

    func testDeletionRejectsOutsideRootAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try OwnedStoragePath.validate(outside, inside: root))
        XCTAssertThrowsError(try OwnedStoragePath.validate(link, inside: root))
        XCTAssertThrowsError(try OwnedStoragePath.validate(root, inside: root))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    func testDeletionRejectsSymlinkAncestor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try Data().write(to: outside.appendingPathComponent("file"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try OwnedStoragePath.validate(link.appendingPathComponent("file"), inside: root))
    }

    func testRetainedPayloadRequiresExplicitRemoval() {
        let policy = StorageRemovalPolicy.payload(signature: "abc", retainedSignatures: ["abc": "Guest"])
        XCTAssertEqual(policy.owner, "Guest")
        XCTAssertTrue(policy.requiresSourceConfirmation)
        XCTAssertFalse(StorageRemovalPolicy.payload(signature: "unused", retainedSignatures: [:]).requiresSourceConfirmation)
    }
    func testChangedOwnershipRequiresFreshConsent() {
        let unused = StorageRemovalPolicy(owner: nil, requiresSourceConfirmation: false)
        let retained = StorageRemovalPolicy(owner: "App A", requiresSourceConfirmation: true)
        let otherOwner = StorageRemovalPolicy(owner: "App B", requiresSourceConfirmation: true)
        XCTAssertFalse(retained.canRemove(consent: unused, allowRetainedSource: false))
        XCTAssertFalse(otherOwner.canRemove(consent: retained, allowRetainedSource: true))
        XCTAssertFalse(retained.canRemove(consent: retained, allowRetainedSource: false))
        XCTAssertTrue(retained.canRemove(consent: retained, allowRetainedSource: true))
        XCTAssertTrue(unused.canRemove(consent: unused, allowRetainedSource: false))
    }

    func testSameDisplayNameDoesNotAuthorizeDifferentInstallationOwner() {
        let first = StorageRemovalPolicy(owner: "App", requiresSourceConfirmation: true, ownerIdentifiers: ["product.A"])
        let second = StorageRemovalPolicy(owner: "App", requiresSourceConfirmation: true, ownerIdentifiers: ["product.B"])
        XCTAssertFalse(second.canRemove(consent: first, allowRetainedSource: true))
    }

}
