import XCTest
@testable import SideKickCore

final class StorageArchiveImportanceTests: XCTestCase {
    func testOnlyCurrentInstalledVersionNeedsAWarning() {
        let installed = [StorageInstalledVersion(identifiers: ["com.test", "com.test.TEAM"], name: "Test", version: "2.0", build: "20")]
        XCTAssertNil(StorageArchiveImportance.owner(bundleID: "com.test", version: "1.0", build: "10", installed: installed))
        XCTAssertNil(StorageArchiveImportance.owner(bundleID: "com.test", version: "2.0", build: "19", installed: installed))
        XCTAssertEqual(StorageArchiveImportance.owner(bundleID: "com.test.TEAM", version: "2.0", build: "20", installed: installed), "Test")
        XCTAssertNil(StorageArchiveImportance.owner(bundleID: "com.other", version: "2.0", build: "20", installed: installed))
    }
}
