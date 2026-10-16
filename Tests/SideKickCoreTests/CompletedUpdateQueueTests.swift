import Foundation
import XCTest
@testable import SideKickCore

final class CompletedUpdateQueueTests: XCTestCase {
    private func queued(target: String? = "self.TEAM", binary: String? = "binary-125", build: String? = "125", version: String = "0.8.0") -> ImportedIPA {
        ImportedIPA(bundleIdentifier: "self", name: "SideKick", version: version, fileName: "queued.ipa", sourceBookmarkData: nil, sourceURLString: nil, importedAt: .now, iconData: nil, buildVersion: build, executableIdentity: binary, queuedForInstalledAppID: target)
    }

    func testOnlyExactRunningSelfUpdateIsCompleted() {
        let current = queued()
        let newer = queued(binary: "binary-126", build: "126")
        let otherTeam = queued(target: "self.OTHER")
        let guest = queued(target: "livecontainer:guest")
        let unverified = queued(binary: nil)
        let libraryCopy = queued(target: nil)
        var notQueued = queued()
        notQueued.isQueuedForUpdate = false
        let imports = [current, newer, otherTeam, guest, unverified, libraryCopy,
                       notQueued, queued(build: "126"), queued(version: "0.9.0")]
        XCTAssertEqual(IPAImportIndex.completedSelfUpdates(in: imports, targetID: "self.TEAM", version: "0.8.0", build: "125", executableIdentity: "binary-125"), [current])
        XCTAssertTrue(IPAImportIndex.completedSelfUpdates(in: imports, targetID: "self.TEAM", version: "0.8.0", build: "125", executableIdentity: "").isEmpty)
        // Recovery is independent of the current GitHub source or a pending receipt:
        // those can change during an Actions-to-Releases migration.
        XCTAssertNil(current.githubSourceIdentity)
        XCTAssertNil(current.githubUpdateKey)
    }
}
