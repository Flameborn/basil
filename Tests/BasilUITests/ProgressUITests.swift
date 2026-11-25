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

    func testTransferShowsCurrentFileTotalSpeedAndTimeLeft() throws {
        XCTAssertTrue(leftTable.waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Debug"].click()
        app.menuItems["Add Test Transfer"].click()
        let window = app.dialogs["Test transfer 1"]
        XCTAssertTrue(window.waitForExistence(timeout: 3), app.debugDescription)

        let file = window.progressIndicators["Current file"]
        let total = window.progressIndicators["Total"]
        XCTAssertTrue(file.waitForExistence(timeout: 3), window.debugDescription)
        XCTAssertTrue(total.exists, window.debugDescription)
        XCTAssertTrue(window.staticTexts["File: first.bin"].exists, window.debugDescription)
        XCTAssertTrue(window.staticTexts["From: /Users/test/Source"].exists, window.debugDescription)
        XCTAssertTrue(window.staticTexts["To: /Users/test/Target"].exists, window.debugDescription)

        // After the warm-up the speed (about 2.5 MB a second) and the time left show.
        let timing = window.staticTexts["progress.timing"]
        func timingText() -> String { (timing.value as? String) ?? timing.label }
        XCTAssertTrue(waitFor({ timingText().contains("per second") && timingText().contains("left") }, timeout: 5), timingText())
        func text(_ id: String) -> String {
            let e = window.staticTexts[id]
            return (e.value as? String) ?? e.label
        }
        XCTAssertTrue(waitFor({ text("progress.total").hasSuffix("of 3 files") }, timeout: 3), text("progress.total"))
        XCTAssertTrue(text("progress.total").hasPrefix("Total: "), text("progress.total"))
        XCTAssertTrue(text("progress.file").hasPrefix("Current file: ") && text("progress.file").hasSuffix("of 9.5 MB"),
                      text("progress.file"))

        try audit(app) { issue in
            if self.isCoveredElsewhere(issue, by: window) { return true }
            print("AUDIT transfer: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(400) ?? "nil")")
            return false
        }

        // The second file follows.
        XCTAssertTrue(window.staticTexts["File: second.bin"].waitForExistence(timeout: 8), window.debugDescription)
        window.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitFor { !window.exists }, app.debugDescription)
    }
}

/// A delete that fails asks its question on the progress window, in front and with focus, and
/// the question's Cancel stops the item and closes the window.
@MainActor
final class ProgressPromptUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["BASIL_UITEST_FIXTURE"] = "1"
        app.launchEnvironment["BASIL_UITEST_PROGRESS"] = "1"
        app.launchEnvironment["BASIL_UITEST_LOCKED"] = "1"
        app.launch()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    func waitFor(_ predicate: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return predicate()
    }

    func testFailedDeleteAsksOnTheProgressWindow() throws {
        let table = app.tables["pane.left.table"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        table.typeKey("l", modifierFlags: [])   // type-ahead to Locked
        XCTAssertTrue(waitFor { table.tableRows.element(boundBy: 2).isSelected }, table.debugDescription)
        table.typeKey(.F8, modifierFlags: .shift)
        let confirm = app.sheets.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(confirm.buttons["Delete"].exists, confirm.debugDescription)
        app.typeKey(.return, modifierFlags: [])

        let progress = app.dialogs["Delete Locked"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5), app.debugDescription)
        let question = progress.sheets.firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5), progress.debugDescription)
        XCTAssertTrue(question.staticTexts["Cannot delete x"].exists, question.debugDescription)
        XCTAssertTrue(question.buttons["Retry"].exists && question.buttons["Skip"].exists, question.debugDescription)

        try audit(app) { issue in
            if self.isCoveredElsewhere(issue, by: question) { return true }
            // The system NSAlert draws its informative text on translucent glass; the audit misreads
            // it as it does for the delete confirmation (see testFileOperationsWithKeyboard in PaneUITests).
            if issue.auditType == .contrast, (issue.element?.value as? String)?.hasPrefix("No permission for") == true { return true }
            print("AUDIT progress question: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(400) ?? "nil")")
            return false
        }

        // Keys reach the question: Escape is its Cancel, which stops the item and closes the window.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitFor { !progress.exists }, app.debugDescription)
        XCTAssertTrue(waitFor { table.tableRows.element(boundBy: 2).exists })
    }
}
