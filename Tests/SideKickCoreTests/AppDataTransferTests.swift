import Foundation
import XCTest
@testable import SideKickCore

final class AppDataTransferTests: XCTestCase {
    func testRoundTripPreservesHiddenFilesAndGuestDeletions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("native")
        let exports = root.appendingPathComponent("exports")
        for directory in [home.appendingPathComponent("Documents"), home.appendingPathComponent("Library/Preferences"), exports] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("save".utf8).write(to: home.appendingPathComponent("Documents/.save"))
        try Data("old".utf8).write(to: home.appendingPathComponent("Documents/delete-me"))
        let live = try AppDataTransfer.export(home: home, destination: exports, identity: "test.app", version: "1", build: "2")
        try FileManager.default.removeItem(at: live.appendingPathComponent("Documents/delete-me"))
        try Data("new".utf8).write(to: live.appendingPathComponent("Library/Preferences/test.app.plist"))
        _ = try AppDataTransfer.restore(live: live, home: home, identity: "test.app", version: "1", build: "2")
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("Documents/.save")), Data("save".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Documents/delete-me").path))
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("Library/Preferences/test.app.plist")), Data("new".utf8))
    }

    func testWrongIdentityAndLinksCannotOverwriteNativeData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("native")
        let exports = root.appendingPathComponent("exports")
        for directory in [home.appendingPathComponent("Documents"), home.appendingPathComponent("Library"), exports] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("keep".utf8).write(to: home.appendingPathComponent("Documents/save"))
        let live = try AppDataTransfer.export(home: home, destination: exports, identity: "test.app", version: "1", build: "2")
        XCTAssertThrowsError(try AppDataTransfer.restore(live: live, home: home, identity: "other.app", version: "1", build: "2"))
        XCTAssertThrowsError(try AppDataTransfer.restore(live: live, home: home, identity: "test.app", version: "1", build: "3"))
        try FileManager.default.createSymbolicLink(at: live.appendingPathComponent("Documents/escape"), withDestinationURL: root)
        XCTAssertThrowsError(try AppDataTransfer.restore(live: live, home: home, identity: "test.app", version: "1", build: "2"))
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("Documents/save")), Data("keep".utf8))
    }

    func testExportRejectsDestinationInsideNativeHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try AppDataTransfer.export(home: root, destination: root.appendingPathComponent("Documents"), identity: "test.app", version: "1", build: "2"))
    }
}
