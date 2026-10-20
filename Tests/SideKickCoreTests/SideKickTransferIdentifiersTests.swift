import XCTest
@testable import SideKickCore

final class SideKickTransferIdentifiersTests: XCTestCase {
    func testRewritesAppAndExtensionIdentifiers() {
        XCTAssertEqual(SideKickTransferIdentifiers.rewrite("com.app.ABCDE12345", from: "com.app.ABCDE12345", to: "com.app"), "com.app")
        XCTAssertEqual(SideKickTransferIdentifiers.rewrite("com.app.ABCDE12345.Widget", from: "com.app.ABCDE12345", to: "com.app"),
                       "com.app.Widget")
    }

    func testLeavesUnrelatedIdentifiersAlone() {
        XCTAssertNil(SideKickTransferIdentifiers.rewrite("com.application", from: "com.app", to: "com.other"))
        XCTAssertNil(SideKickTransferIdentifiers.rewrite("org.example", from: "com.app", to: "com.other"))
    }
}
