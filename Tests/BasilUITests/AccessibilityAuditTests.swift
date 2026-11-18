import XCTest

final class AccessibilityAuditTests: XCTestCase {
    @MainActor
    func testMainWindowPassesAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        try app.performAccessibilityAudit()
    }

    @MainActor
    func testBothPanesAreExposedToVoiceOver() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.groups["pane.left"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.groups["pane.right"].exists)
    }
}
