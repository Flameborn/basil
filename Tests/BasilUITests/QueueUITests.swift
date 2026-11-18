import XCTest

/// The operation queue panel (Cmd+J), driven with the keyboard. Items come from the
/// Debug menu's "Add Test Operation" (a 10-second fake operation).
@MainActor
final class QueueUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["BASIL_UITEST_FIXTURE"] = "1"
        app.launch()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    var leftTable: XCUIElement { app.tables["pane.left.table"] }
    var panel: XCUIElement { app.windows["Operation Queue"] }
    var list: XCUIElement { panel.descendants(matching: .any)["queue.list"] }

    func addTestOperation() {
        app.menuBars.menuBarItems["Debug"].click()
        app.menuItems["Add Test Operation"].click()
    }

    /// The queue rows' spoken labels, in order.
    /// Read from one snapshot: the rows change while the test runs, so querying them one by one races.
    func rowLabels() -> [String] {
        guard let root = try? list.snapshot() else { return [] }
        var result: [String] = []
        func walk(_ s: any XCUIElementSnapshot) {
            if s.identifier == "queue.row" { result.append((s.value as? String) ?? s.label) }
            s.children.forEach(walk)
        }
        walk(root)
        return result
    }

    func waitFor(_ predicate: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return predicate()
    }

    func testQueueOpensClosesAndControlsItemsByKeyboard() throws {
        XCTAssertTrue(leftTable.waitForExistence(timeout: 5))
        addTestOperation()
        addTestOperation()
        leftTable.typeKey("j", modifierFlags: .command)
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        XCTAssertTrue(waitFor { self.rowLabels().count == 2 }, list.debugDescription)
        XCTAssertTrue(rowLabels()[0].hasPrefix("Test operation 1, running"), rowLabels()[0])
        XCTAssertTrue(rowLabels()[1].hasPrefix("Test operation 2, waiting"), rowLabels()[1])

        // The cursor starts on the running item, in the focused list. Space pauses it.
        XCTAssertTrue(waitFor { (self.list.value(forKey: "hasKeyboardFocus") as? Bool) == true })
        panel.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(waitFor { self.rowLabels().first?.hasPrefix("Test operation 1, paused") == true }, "\(rowLabels())")
        panel.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(waitFor { self.rowLabels().first?.hasPrefix("Test operation 1, running") == true }, "\(rowLabels())")

        // Cmd+Down moves it below the second item.
        panel.typeKey(.downArrow, modifierFlags: .command)
        XCTAssertTrue(waitFor { self.rowLabels().first?.hasPrefix("Test operation 2") == true }, "\(rowLabels())")

        // Delete removes the selected (running) item: it is cancelled and dropped, and the other one starts.
        panel.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitFor { self.rowLabels().count == 1 }, "\(rowLabels())")
        XCTAssertTrue(waitFor { self.rowLabels().first?.hasPrefix("Test operation 2, running") == true }, "\(rowLabels())")

        try app.performAccessibilityAudit { issue in
            if issue.auditType == .action, let element = issue.element, !element.isEnabled {
                return true // disabled buttons (e.g. "Remove Finished" with nothing finished)
            }
            print("AUDIT queue: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }

        // Escape closes the panel; Cmd+J opens it again and closes it again.
        panel.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitFor { !self.panel.exists })
        leftTable.typeKey("j", modifierFlags: .command)
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        panel.typeKey("j", modifierFlags: .command)
        XCTAssertTrue(waitFor { !self.panel.exists })
    }

    func testFinishedItemsCanBeRemoved() {
        XCTAssertTrue(leftTable.waitForExistence(timeout: 5))
        addTestOperation()
        leftTable.typeKey("j", modifierFlags: .command)
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        XCTAssertTrue(waitFor({ self.rowLabels().first?.hasPrefix("Test operation 1, finished") == true }, timeout: 20), "rows=\(rowLabels()) panelExists=\(panel.exists)")
        panel.buttons["Remove Finished"].click()
        XCTAssertTrue(waitFor { self.rowLabels().isEmpty })
    }
}
