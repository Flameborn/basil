import XCTest

/// The Full Disk Access window at launch. BASIL_UITEST_FDA=1 makes access count as granted three
/// seconds after the window opened.
@MainActor
final class FullDiskAccessUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["BASIL_UITEST_FIXTURE"] = "1"
        app.launchEnvironment["BASIL_UITEST_FDA"] = "1"
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

    func testContinueOnlyOnceAccessIsGranted() throws {
        let window = app.windows["Full Disk Access"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let status = window.staticTexts["fullDiskAccess.status"]
        let continueButton = window.buttons["Continue"]
        XCTAssertEqual(status.value as? String, "Status: not granted")
        XCTAssertFalse(continueButton.isEnabled)
        XCTAssertTrue(window.buttons["Quit Basil"].exists)
        XCTAssertTrue(window.buttons["Open System Settings"].exists)
        XCTAssertFalse(app.tables["pane.left.table"].exists)

        XCTAssertTrue(waitFor({ (status.value as? String) == "Status: granted" }, timeout: 6), "\(status.value ?? "")")
        XCTAssertTrue(continueButton.isEnabled)
        try audit(app) { issue in
            // Disabled controls are a documented exception; nothing is disabled any more here.
            print("AUDIT full disk access: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        continueButton.click()
        XCTAssertTrue(app.tables["pane.left.table"].waitForExistence(timeout: 5))
        XCTAssertFalse(window.exists)
    }
}
