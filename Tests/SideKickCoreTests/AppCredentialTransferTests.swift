import Foundation
import XCTest
@testable import SideKickCore

final class AppCredentialTransferTests: XCTestCase {
    private let destination = AppCredentialDestination(container: "SideKickData-test", group: "ABCDEFGHIJ.com.kdt.livecontainer.shared.1")
    private let item = AppCredentialItem(attributes: ["class": "genp", "acct": "test", "svce": "fixture"], secret: Data("test-fixture".utf8))

    func testSignerRequiresExactOrBoundedWildcardPermissions() {
        let source = "ABCDEFGHIJ.native"
        XCTAssertEqual(AppCredentialSigningPolicy.groups(source: [source], destination: destination.group, team: "ABCDEFGHIJ", permitted: [source, destination.group])?.count, 2)
        XCTAssertEqual(AppCredentialSigningPolicy.groups(source: [source], destination: destination.group, team: "ABCDEFGHIJ", permitted: ["ABCDEFGHIJ.*"])?.count, 2)
        for permitted in [[source], ["*"], ["ABCDEFGHI.*"], ["ABCDEFGHIJ.*.*"]] {
            XCTAssertNil(AppCredentialSigningPolicy.groups(source: [source], destination: destination.group, team: "ABCDEFGHIJ", permitted: permitted))
        }
        XCTAssertNil(AppCredentialSigningPolicy.groups(source: ["OTHERTEAM1.native"], destination: destination.group, team: "ABCDEFGHIJ", permitted: ["ABCDEFGHIJ.*"]))
        XCTAssertNil(AppCredentialSigningPolicy.groups(source: [source], destination: "ABCDEFGHIJ.com.kdt.livecontainer.shared.evil", team: "ABCDEFGHIJ", permitted: ["ABCDEFGHIJ.*"]))
        XCTAssertNil(AppCredentialSigningPolicy.groups(source: [destination.group], destination: destination.group, team: "ABCDEFGHIJ", permitted: ["ABCDEFGHIJ.*"]))
    }

    func testCopiesVerifiesAndRetriesWithoutDuplicating() throws {
        let store = MemoryCredentials()
        store.source = [item]
        try AppCredentialTransfer.copy(groups: ["ABCDEFGHIJ.native"], destination: destination, store: store)
        try AppCredentialTransfer.copy(groups: ["ABCDEFGHIJ.native"], destination: destination, store: store)
        XCTAssertEqual(store.insertions, 1)
        XCTAssertEqual(store.source[0].secret, item.secret)
        XCTAssertEqual(store.saved.count, 1)
    }

    func testConflictPreservesExistingAndNativeCredentials() {
        let store = MemoryCredentials()
        store.source = [item]
        let old = AppCredentialItem(attributes: item.attributes, secret: Data("other-fixture".utf8))
        store.saved[Data([0])] = old
        XCTAssertThrowsError(try AppCredentialTransfer.copy(groups: ["ABCDEFGHIJ.native"], destination: destination, store: store))
        XCTAssertEqual(store.insertions, 0)
        XCTAssertEqual(store.saved[Data([0])]?.secret, old.secret)
        XCTAssertEqual(store.source[0].secret, item.secret)
    }

    func testFailedReadbackRollsBackOnlyNewItems() {
        let store = MemoryCredentials()
        store.source = [item]
        let unrelated = AppCredentialItem(attributes: ["acct": "unrelated"], secret: Data([4]))
        store.saved[Data([0])] = unrelated
        store.corruptReadback = true
        XCTAssertThrowsError(try AppCredentialTransfer.copy(groups: ["ABCDEFGHIJ.native"], destination: destination, store: store))
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved[Data([0])]?.secret, unrelated.secret)
        XCTAssertEqual(store.source[0].secret, item.secret)
    }

    func testUnsupportedItemsAndOverlappingGroupsNeverWrite() {
        let store = MemoryCredentials()
        store.rejectSource = true
        XCTAssertThrowsError(try AppCredentialTransfer.copy(groups: ["ABCDEFGHIJ.native"], destination: destination, store: store))
        XCTAssertThrowsError(try AppCredentialTransfer.copy(groups: [destination.group], destination: destination, store: store))
        XCTAssertThrowsError(try AppCredentialTransfer.copy(groups: ["ABCDEFGHIJ.*"], destination: destination, store: store))
        XCTAssertEqual(store.insertions, 0)
    }

    func testTwoSourceGroupsWithConflictingIdentitiesRollBack() {
        let store = MemoryCredentials()
        store.source = [item, AppCredentialItem(attributes: item.attributes, secret: Data([9]))]
        XCTAssertThrowsError(try AppCredentialTransfer.copy(groups: ["ABCDEFGHIJ.one", "ABCDEFGHIJ.two"], destination: destination, store: store))
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testDestinationRequiresExactAppIsolationAndIntegerBucket() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SideKickData-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ bucket: Any, app: String = "native", isolated: Bool = true) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["appIdentifier": app, "isolateAppGroup": isolated, "keychainGroupId": bucket], format: .binary, options: 0)
            try data.write(to: root.appendingPathComponent("LCContainerInfo.plist"))
        }
        try write(1)
        XCTAssertEqual(try AppCredentialDestination.read(folder: root, appID: "native", team: "ABCDEFGHIJ").group, destination.group)
        for bucket in [true, -1, 128, 1.5, "1"] as [Any] {
            try write(bucket)
            XCTAssertThrowsError(try AppCredentialDestination.read(folder: root, appID: "native", team: "ABCDEFGHIJ"))
        }
        try write(1, app: "other")
        XCTAssertThrowsError(try AppCredentialDestination.read(folder: root, appID: "native", team: "ABCDEFGHIJ"))
        try write(1, isolated: false)
        XCTAssertThrowsError(try AppCredentialDestination.read(folder: root, appID: "native", team: "ABCDEFGHIJ"))
    }
}

private final class MemoryCredentials: AppCredentialStore {
    var source: [AppCredentialItem] = []
    var saved: [Data: AppCredentialItem] = [:]
    var insertions = 0
    var corruptReadback = false
    var rejectSource = false
    func readSource(groups: [String]) throws -> [AppCredentialItem] {
        if rejectSource { throw AppCredentialTransferError.protectedItems }
        return source
    }
    func existing(_ item: AppCredentialItem, destination: AppCredentialDestination) throws -> AppCredentialItem? {
        saved.values.first { NSDictionary(dictionary: $0.attributes).isEqual(to: item.attributes) }
    }
    func insert(_ item: AppCredentialItem, destination: AppCredentialDestination) throws -> Data {
        insertions += 1
        let reference = Data([UInt8(insertions)])
        saved[reference] = item
        return reference
    }
    func readInserted(reference: Data, original: AppCredentialItem) throws -> AppCredentialItem {
        let item = saved[reference]!
        return corruptReadback ? AppCredentialItem(attributes: item.attributes, secret: Data()) : item
    }
    func removeInserted(reference: Data) throws { saved.removeValue(forKey: reference) }
}
