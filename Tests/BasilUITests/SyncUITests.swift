import XCTest

extension PaneUITests {
    /// Commands > Synchronize Directories: Alpha against the empty Beta finds Inner (with
    /// pack.zip) on the left only; the direction keys change it; synchronizing copies it and the
    /// window compares again.
    func testSynchronizeDirectoriesComparesAndCopies() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["Commands"].click()
        menuBar.menuItems["Synchronize Directories..."].click()
        let window = app.windows["Synchronize Directories"]
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        let left = window.textFields["sync.left"], right = window.textFields["sync.right"]
        XCTAssertTrue(waitFor { (left.value(forKey: "hasKeyboardFocus") as? Bool) == true })
        left.typeKey("a", modifierFlags: .command)
        left.typeText("Alpha")
        right.click()
        right.typeKey("a", modifierFlags: .command)
        right.typeText("Beta\r")
        let status = window.staticTexts["sync.status"]
        func statusText() -> String { status.value as? String ?? "" }
        XCTAssertTrue(waitFor({ statusText().hasPrefix("1 to copy to the right") }, timeout: 10), statusText())
        let list = window.tables["sync.results"]
        let row = list.staticTexts.firstMatch
        XCTAssertTrue(waitFor { (row.value as? String)?.hasPrefix("Inner, folder, only on the left, copy to the right, left") == true },
                      "\(row.value ?? "")")
        // Tab out of any field before auditing (the field editor confuses the audit).
        try audit(app) { issue in
            if self.isCoveredElsewhere(issue, by: window) { return true }
            print("AUDIT sync: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        list.click()
        list.typeKey("=", modifierFlags: [])
        XCTAssertTrue(waitFor { (row.value as? String)?.contains("leave alone") == true }, "\(row.value ?? "") | \(statusText())")
        // Nothing on the right to copy back: stays as it is.
        list.typeKey(",", modifierFlags: [])
        XCTAssertTrue((row.value as? String)?.contains("leave alone") == true)
        list.typeKey(".", modifierFlags: [])
        XCTAssertTrue(waitFor { (row.value as? String)?.contains("copy to the right") == true }, "\(row.value ?? "")")

        window.buttons["Synchronize Now"].click()
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        XCTAssertTrue(sheet.staticTexts["Synchronize Alpha and Beta?"].exists, sheet.debugDescription)
        sheet.buttons["Synchronize"].click()
        XCTAssertTrue(waitFor({ statusText() == "1 equal." }, timeout: 15), statusText())
        window.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitFor { !window.exists })
    }
}
