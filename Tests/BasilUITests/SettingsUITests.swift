import XCTest

extension PaneUITests {
    func openSettingsSection(_ title: String) -> XCUIElement {
        leftTable.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Basil Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        let row = settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 2), settings.debugDescription)
        row.click()
        return settings
    }

    /// The sidebar has General (updates) and Search (the index of the startup disk and other volumes).
    func testSettingsSidebarGeneralAndSearch() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        let settings = openSettingsSection("General")
        let updates = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Check for updates automatically'")).firstMatch
        XCTAssertTrue(updates.waitForExistence(timeout: 2), settings.debugDescription)
        XCTAssertTrue(settings.buttons["Check for Updates Now"].exists)
        settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Search' OR value == 'Search'")).firstMatch.click()
        let boot = settings.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH ', startup disk'")).firstMatch
        XCTAssertTrue(boot.waitForExistence(timeout: 2), settings.debugDescription)
        XCTAssertEqual(boot.value as? Int, 1)
        try audit(app) { issue in
            if self.isCoveredElsewhere(issue, by: settings) { return true }
            print("AUDIT settings search: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        settings.typeKey("w", modifierFlags: .command)
    }

    /// Themes: Basil's own is read only; a duplicate can be changed, and a colour that would be
    /// unreadable is refused with the reason.
    func testThemesRefuseUnreadableColours() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        let settings = openSettingsSection("Themes")
        settings.buttons["Duplicate Theme"].click()
        let message = settings.staticTexts["themes.message"]
        func messageText() -> String { message.value as? String ?? message.label }
        XCTAssertTrue(waitFor { messageText() == "Made Basil copy" }, messageText())
        let field = settings.textFields["Text, light"]
        XCTAssertTrue(field.waitForExistence(timeout: 2), settings.debugDescription)
        XCTAssertEqual(field.value as? String, "#1A1A1A")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("#DDDDDD\r")
        XCTAssertTrue(waitFor { messageText().hasPrefix("Not changed: Text on pane background would be") }, messageText())
        XCTAssertTrue(waitFor { (field.value as? String) == "#1A1A1A" }, "\(field.value ?? "")")
        field.typeKey("a", modifierFlags: .command)
        field.typeText("#000000\r")
        XCTAssertTrue(waitFor { (field.value as? String) == "#000000" }, "\(field.value ?? "")")
        // Out of the field before auditing (a field being edited confuses the audit).
        settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Themes'")).firstMatch.click()
        try audit(app) { issue in
            if issue.auditType == .action, let element = issue.element,
               element.elementType == .popUpButton || element.elementType == .colorWell || !element.isEnabled { return true }
            if self.isCoveredElsewhere(issue, by: settings) { return true }
            // A row cut off by the bottom of the scrolling colour list (its screenshot is cropped).
            if issue.auditType == .contrast, let element = issue.element,
               element.frame.maxY > settings.frame.maxY - 24 { return true }
            print("AUDIT themes: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        settings.buttons["Delete Theme"].click()
        XCTAssertTrue(waitFor { messageText().hasPrefix("Deleted Basil copy") }, messageText())
        settings.typeKey("w", modifierFlags: .command)
    }
}
