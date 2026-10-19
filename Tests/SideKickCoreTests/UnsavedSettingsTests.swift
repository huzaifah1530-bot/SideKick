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

    /// The installed build is chosen on a page pushed over Update Source. Switching tabs
    /// from there must still ask about the covered page's edit.
    func testCoveredPageWithEditsStillAsksWhenSwitchingTabs() async {
        let guardState = UnsavedSettingsCoordinator()
        var events: [String] = []
        let source = UUID(), child = UUID()
        guardState.register(owner: source, isDirty: false, save: { events.append("save source"); return true }, discard: {})
        guardState.register(owner: child, isDirty: false, save: { true }, discard: {})
        guardState.register(owner: source, isDirty: true, save: { events.append("save source"); return true }, discard: {})
        XCTAssertTrue(guardState.hasUnsavedChanges)
        guardState.requestNavigation { events.append("leave") }
        XCTAssertTrue(guardState.isPresented)
        await guardState.saveAndLeave()
        XCTAssertEqual(events, ["save source", "leave"])
        XCTAssertFalse(guardState.hasUnsavedChanges)
    }

    func testBackButtonOnlyConsidersItsOwnPage() {
        let guardState = UnsavedSettingsCoordinator()
        let parent = UUID(), child = UUID()
        var left = false
        guardState.register(owner: parent, isDirty: true, save: { true }, discard: {})
        guardState.register(owner: child, isDirty: false, save: { true }, discard: {})
        guardState.requestNavigation(from: child) { left = true }
        XCTAssertTrue(left)
        XCTAssertFalse(guardState.isPresented)
        XCTAssertTrue(guardState.hasUnsavedChanges)
    }

    func testDiscardRunsForEveryEditedPage() {
        let guardState = UnsavedSettingsCoordinator()
        var events: [String] = []
        guardState.register(owner: UUID(), isDirty: true, save: { true }, discard: { events.append("outer") })
        guardState.register(owner: UUID(), isDirty: true, save: { true }, discard: { events.append("inner") })
        guardState.requestNavigation { events.append("leave") }
        guardState.discardAndLeave()
        XCTAssertEqual(events, ["inner", "outer", "leave"])
    }
}
