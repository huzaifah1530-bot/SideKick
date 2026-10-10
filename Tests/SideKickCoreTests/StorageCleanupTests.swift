import Foundation
import XCTest
@testable import SideKickCore

final class StorageCleanupTests: XCTestCase {
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
