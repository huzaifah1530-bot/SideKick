import Foundation
import XCTest
@testable import SideKickCore

final class AppDataTransferTests: XCTestCase {
    func testAppGroupMappingRequiresExactGrantedIdentity() throws {
        XCTAssertEqual(try AppDataTransfer.groupMappings(original: ["group.test"], entitled: ["group.test.ABCDE12345"]), ["group.test": "group.test.ABCDE12345"])
        XCTAssertEqual(try AppDataTransfer.groupMappings(original: ["group.test"], entitled: ["group.test"]), ["group.test": "group.test"])
        XCTAssertThrowsError(try AppDataTransfer.groupMappings(original: ["group.test"], entitled: ["group.testing.ABCDE12345"]))
        XCTAssertThrowsError(try AppDataTransfer.groupMappings(original: ["group.test"], entitled: ["group.test.ABCDE12345", "group.test.OTHER12345"]))
        XCTAssertThrowsError(try AppDataTransfer.groupMappings(original: ["group.test"], entitled: []))
        XCTAssertThrowsError(try AppDataTransfer.groupMappings(original: ["group.test", "group.test"], entitled: ["group.test"]))
        XCTAssertThrowsError(try AppDataTransfer.groupMappings(original: ["group../escape"], entitled: ["group../escape"]))
    }

    func testAppGroupsRoundTripAndGuestDeletionsPreserveSystemMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("native")
        let group = root.appendingPathComponent("group")
        let exports = root.appendingPathComponent("exports")
        for folder in [home.appendingPathComponent("Documents"), home.appendingPathComponent("Library"), group.appendingPathComponent("Library/Preferences"), exports] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let groupID = "group.test.app"
        try Data("keep-system".utf8).write(to: group.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist"))
        try Data("native-save".utf8).write(to: group.appendingPathComponent("save.db"))
        try Data("delete".utf8).write(to: group.appendingPathComponent("delete-me"))
        try Data("native-prefs".utf8).write(to: group.appendingPathComponent("Library/Preferences/" + groupID + ".plist"))
        let live = try AppDataTransfer.export(home: home, destination: exports, identity: "test.app", version: "1", build: "2", appGroups: [groupID: group])
        XCTAssertEqual(try AppDataTransfer.readIdentity(at: live).appGroupIdentifiers, [groupID])
        let guestGroup = live.appendingPathComponent("LCAppGroup/" + groupID)
        XCTAssertEqual(try Data(contentsOf: live.appendingPathComponent("Library/Preferences/" + groupID + ".plist")), Data("native-prefs".utf8))
        try Data("guest-prefs".utf8).write(to: live.appendingPathComponent("Library/Preferences/" + groupID + ".plist"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: guestGroup.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist").path))
        try Data("guest-save".utf8).write(to: guestGroup.appendingPathComponent("save.db"))
        try FileManager.default.removeItem(at: guestGroup.appendingPathComponent("delete-me"))
        _ = try AppDataTransfer.restore(live: live, home: home, identity: "test.app", version: "1", build: "2", appGroups: [groupID: group])
        XCTAssertEqual(try Data(contentsOf: group.appendingPathComponent("save.db")), Data("guest-save".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: group.appendingPathComponent("delete-me").path))
        XCTAssertEqual(try Data(contentsOf: group.appendingPathComponent("Library/Preferences/" + groupID + ".plist")), Data("guest-prefs".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Preferences/" + groupID + ".plist").path))
        let nextExport = try AppDataTransfer.export(home: home, destination: exports, identity: "test.app", version: "1", build: "2", appGroups: [groupID: group])
        XCTAssertEqual(try Data(contentsOf: nextExport.appendingPathComponent("Library/Preferences/" + groupID + ".plist")), Data("guest-prefs".utf8))
        XCTAssertEqual(try Data(contentsOf: group.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")), Data("keep-system".utf8))
        try FileManager.default.removeItem(at: live.appendingPathComponent("Library/Preferences/" + groupID + ".plist"))
        _ = try AppDataTransfer.restore(live: live, home: home, identity: "test.app", version: "1", build: "2", appGroups: [groupID: group])
        XCTAssertFalse(FileManager.default.fileExists(atPath: group.appendingPathComponent("Library/Preferences/" + groupID + ".plist").path))
    }

    func testMissingGroupOrUnsafeGroupFailsBeforeChangingHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("native")
        let group = root.appendingPathComponent("group")
        let exports = root.appendingPathComponent("exports")
        for folder in [home.appendingPathComponent("Documents"), home.appendingPathComponent("Library"), group, exports] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("native".utf8).write(to: home.appendingPathComponent("Documents/save"))
        let live = try AppDataTransfer.export(home: home, destination: exports, identity: "test.app", version: "1", build: "2", appGroups: ["group.test": group])
        try Data("guest".utf8).write(to: live.appendingPathComponent("Documents/save"))
        XCTAssertThrowsError(try AppDataTransfer.restore(live: live, home: home, identity: "test.app", version: "1", build: "2"))
        try FileManager.default.createSymbolicLink(at: live.appendingPathComponent("LCAppGroup/group.test/escape"), withDestinationURL: root)
        XCTAssertThrowsError(try AppDataTransfer.restore(live: live, home: home, identity: "test.app", version: "1", build: "2", appGroups: ["group.test": group]))
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("Documents/save")), Data("native".utf8))
        XCTAssertThrowsError(try AppDataTransfer.export(home: home, destination: exports, identity: "test.app", version: "1", build: "2", appGroups: ["../escape": group]))
        XCTAssertThrowsError(try AppDataTransfer.export(home: home, destination: exports, identity: "test.app", version: "1", build: "2", appGroups: ["group.test": home]))
    }

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
