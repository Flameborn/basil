import XCTest

extension PaneUITests {
    /// Settings > Plugins lists the fixture's plugin turned off; turned on, its command runs by
    /// its key, asks with a sheet, and makes a folder through Basil's queue.
    func testPluginIsTurnedOnInSettingsAndItsCommandRuns() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Basil Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        let tab = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Plugins'")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 2), settings.debugDescription)
        tab.click()
        let toggle = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Hello Test 1.0'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), settings.debugDescription)
        XCTAssertEqual(toggle.value as? Int, 0, "new plugins are off")
        let status = settings.descendants(matching: .any)["plugin.status.uitest.hello"]
        func statusText() -> String { (status.value as? String) ?? status.label }
        XCTAssertTrue(status.waitForExistence(timeout: 2) && statusText().hasPrefix("Off."), statusText())
        toggle.click()
        XCTAssertTrue(waitFor { (toggle.value as? Int) == 1 })
        XCTAssertTrue(waitFor { statusText().hasPrefix("Running.") }, statusText())
        try audit(app) { issue in
            if self.isCoveredElsewhere(issue, by: settings) { return true }
            print("AUDIT plugin settings: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        settings.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitFor { !settings.exists })

        leftTable.click()
        leftTable.typeKey("h", modifierFlags: [.control, .shift])
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["Who are you?"].exists, sheet.debugDescription)
        waitForFieldFocus(in: sheet)
        sheet.textFields.firstMatch.typeKey("a", modifierFlags: .command)
        app.typeText("From Plugin\r")
        XCTAssertTrue(waitFor({ self.names(in: self.leftTable).contains("From Plugin") }, timeout: 10), "\(names(in: leftTable))")
    }
}
