import XCTest
@testable import SideKickCore

@MainActor final class UnsavedSettingsTests: XCTestCase {
    func testCleanPageLeavesImmediately() async {
        let guardState = UnsavedSettingsCoordinator()
        var left = false
        guardState.register(owner: UUID(), isDirty: false, save: { true }, discard: {})
        guardState.requestNavigation { left = true }
        XCTAssertTrue(left)
        XCTAssertFalse(guardState.isPresented)
    }

    func testDontSaveDiscardsBeforeLeaving() async {
        let guardState = UnsavedSettingsCoordinator()
        var events: [String] = []
        guardState.register(owner: UUID(), isDirty: true, save: { events.append("save"); return true }, discard: { events.append("discard") })
        guardState.requestNavigation { events.append("leave") }
        XCTAssertTrue(guardState.isPresented)
        XCTAssertTrue(events.isEmpty)
        guardState.discardAndLeave()
        XCTAssertEqual(events, ["discard", "leave"])
    }

    func testSaveCompletesBeforeLeaving() async {
        let guardState = UnsavedSettingsCoordinator()
        var events: [String] = []
        guardState.register(owner: UUID(), isDirty: true, save: { events.append("save"); return true }, discard: { events.append("discard") })
        guardState.requestNavigation { events.append("leave") }
        await guardState.saveAndLeave()
        XCTAssertEqual(events, ["save", "leave"])
    }

    func testFailedSaveKeepsPageAndEdits() async {
        let guardState = UnsavedSettingsCoordinator()
        var left = false
        var discarded = false
        let owner = UUID()
        guardState.register(owner: owner, isDirty: true, save: { false }, discard: { discarded = true })
        guardState.requestNavigation { left = true }
        await guardState.saveAndLeave()
        XCTAssertFalse(left)
        XCTAssertFalse(discarded)
        guardState.requestNavigation { left = true }
        XCTAssertTrue(guardState.isPresented)
        guardState.unregister(owner: UUID())
        guardState.discardAndLeave()
        XCTAssertTrue(discarded)
        XCTAssertTrue(left)
    }
}
