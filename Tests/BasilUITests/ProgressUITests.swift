import XCTest

/// The Total Commander-style progress window: it follows the running queue item, takes focus,
/// and has Background, Pause and Cancel. Accessibility sees it as a dialog (a titled panel). Items come from the Debug menu's "Add Test Operation".
@MainActor
final class ProgressUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["BASIL_UITEST_FIXTURE"] = "1"
        app.launchEnvironment["BASIL_UITEST_PROGRESS"] = "1"
        app.launch()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    var leftTable: XCUIElement { app.tables["pane.left.table"] }

    func addTestOperation() {
        app.menuBars.menuBarItems["Debug"].click()
        app.menuItems["Add Test Operation"].click()
    }

    func waitFor(_ predicate: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return predicate()
    }

    func status(_ window: XCUIElement) -> String {
        let text = window.staticTexts["progress.status"]
        return (text.value as? String) ?? text.label
    }

    func testProgressWindowBackgroundPauseAndCancel() throws {
        XCTAssertTrue(leftTable.waitForExistence(timeout: 5))
        addTestOperation()
        let first = app.dialogs["Test operation 1"]
        XCTAssertTrue(first.waitForExistence(timeout: 3), app.debugDescription)
        addTestOperation()
        XCTAssertTrue(first.staticTexts["1 more waiting"].waitForExistence(timeout: 3), first.debugDescription)

        try audit(app) { issue in
            if self.isCoveredElsewhere(issue, by: first) { return true }
            print("AUDIT progress: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(400) ?? "nil")")
            return false
        }

        // Pause and resume.
        first.buttons["Pause"].click()
        XCTAssertTrue(waitFor { self.status(first).hasPrefix("Paused") }, status(first))
        first.buttons["Resume"].click()
        XCTAssertTrue(waitFor { !self.status(first).hasPrefix("Paused") }, status(first))

        // Escape cancels the first item; the window then follows the second one.
        first.typeKey(.escape, modifierFlags: [])
        let second = app.dialogs["Test operation 2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5), app.debugDescription)

        // Return sends it to the background: the window goes and the pane has focus again.
        second.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { !second.exists }, app.debugDescription)
        // Keys go to the pane again: Down moves its cursor.
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 0).isSelected })
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 1).isSelected }, leftTable.debugDescription)
    }
}
