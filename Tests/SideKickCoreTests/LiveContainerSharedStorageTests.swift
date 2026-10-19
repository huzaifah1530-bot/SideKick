import Foundation
import XCTest
@testable import SideKickCore

final class LiveContainerSharedStorageTests: XCTestCase {
    func testOnlyLiveContainerGroupsAreCandidatesInLiveContainersOrder() {
        let groups = ["group.com.sidekick.app.TEAM", "group.com.rileytestut.AltStore.TEAM",
                      "group.com.SideStore.SideStore.TEAM", "group.com.SideStore.SideStoreX"]
        XCTAssertEqual(LiveContainerSharedStorage.candidateGroups(groups),
                       ["group.com.SideStore.SideStore.TEAM", "group.com.rileytestut.AltStore.TEAM"])
    }

    func testGroupWithStoreAppsFolderWinsLikeLiveContainer() {
        let sidestore = URL(fileURLWithPath: "/groups/sidestore")
        let altstore = URL(fileURLWithPath: "/groups/altstore")
        let containers = ["group.com.SideStore.SideStore.TEAM": sidestore, "group.com.rileytestut.AltStore.TEAM": altstore]
        let groups = Array(containers.keys)
        let first = LiveContainerSharedStorage.liveContainerGroup(from: groups, container: { containers[$0] }, fileExists: { _ in false })
        XCTAssertEqual(first?.url, sidestore)
        let withApps = LiveContainerSharedStorage.liveContainerGroup(from: groups, container: { containers[$0] },
                                                                     fileExists: { $0 == altstore.appendingPathComponent("Apps") })
        XCTAssertEqual(withApps?.url, altstore)
        XCTAssertNil(LiveContainerSharedStorage.liveContainerGroup(from: ["group.com.sidekick.app.TEAM"], container: { _ in sidestore }))
        XCTAssertEqual(LiveContainerSharedStorage.applicationsDirectory(in: sidestore).path, "/groups/sidestore/LiveContainer/Applications")
    }

    func testLaunchPrefersInstallationAlreadyRunningTheApp() {
        let lock: [String: Any] = ["DATA-1": ["runningLC": "livecontainer2.liveprocess", "auditToken57": 1]]
        XCTAssertEqual(LiveContainerSharedStorage.launchScheme(dataFolder: "DATA-1", installed: ["livecontainer", "livecontainer2"],
                                                               priority: nil, containerLock: lock), "livecontainer2")
    }

    func testLaunchFollowsUserPriorityAmongInstalledSchemes() {
        XCTAssertEqual(LiveContainerSharedStorage.launchScheme(dataFolder: "DATA-2", installed: ["livecontainer", "livecontainer3"],
                                                               priority: ["LiveContainer3", "livecontainer"], containerLock: [:]), "livecontainer3")
        // A running record for an installation that's gone is ignored.
        let lock: [String: Any] = ["DATA-2": ["runningLC": "livecontainer2"]]
        XCTAssertEqual(LiveContainerSharedStorage.launchScheme(dataFolder: "DATA-2", installed: ["livecontainer"],
                                                               priority: nil, containerLock: lock), "livecontainer")
        XCTAssertEqual(LiveContainerSharedStorage.launchScheme(dataFolder: nil, installed: [], priority: nil, containerLock: nil), "livecontainer")
    }

    func testOrderedSchemesIgnoresUnknownAndDuplicateEntries() {
        XCTAssertEqual(LiveContainerSharedStorage.orderedSchemes(priority: ["livecontainer2", "evil", 4, "livecontainer2"]),
                       ["livecontainer2", "livecontainer", "livecontainer3"])
    }

    func testScannerReadsDataFolderAndSharedLaunchUsesChosenScheme() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("LiveContainer/Applications")
        let app = directory.appendingPathComponent("com.example.app.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.app", "CFBundleVersion": "1"],
                                           format: .binary, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["LCDataUUID": "DATA-9"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("LCAppInfo.plist"))
        let store = LiveContainerStore(fileURL: root.appendingPathComponent("state.json"))
        let shared = try await store.link(directory: directory, name: "Shared", scheme: "livecontainer", storageKind: .sharedDirectory)
        let apps = try await store.snapshot().apps
        let guest = try XCTUnwrap(apps.first)
        XCTAssertEqual(guest.dataFolder, "DATA-9")
        let sharedURL = try await store.launchURL(for: guest.id, sharedScheme: "livecontainer2")
        XCTAssertEqual(sharedURL.scheme, "livecontainer2")
        // Private folders always use their own installation.
        let privateDirectory = root.appendingPathComponent("Private/Applications")
        try FileManager.default.createDirectory(at: privateDirectory.appendingPathComponent("p.app"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "p", "CFBundleVersion": "1"], format: .binary, options: 0)
            .write(to: privateDirectory.appendingPathComponent("p.app/Info.plist"))
        let privateConnection = try await store.link(directory: privateDirectory, name: "LC", scheme: "livecontainer", storageKind: .privateDocuments)
        let allApps = try await store.snapshot().apps
        let privateGuest = try XCTUnwrap(allApps.first { $0.connectionID == privateConnection.id })
        let privateURL = try await store.launchURL(for: privateGuest.id, sharedScheme: "livecontainer2")
        XCTAssertEqual(privateURL.scheme, "livecontainer")
        XCTAssertNotEqual(shared.id, privateConnection.id)
    }
}
