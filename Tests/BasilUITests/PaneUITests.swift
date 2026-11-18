import XCTest

/// Drives the real app against a fixture directory with the keyboard only.
@MainActor
final class PaneUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        // The app builds the fixture itself (Debug only), see App/Sources/UITestFixture.swift:
        // Alpha/Inner/, Beta/, "apple pie.txt", song.mp3, track.flac, notes.md, .secret
        app = XCUIApplication()
        app.launchEnvironment["BASIL_UITEST_FIXTURE"] = "1"
        app.launch()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    var leftTable: XCUIElement { app.tables["pane.left.table"] }
    var rightTable: XCUIElement { app.tables["pane.right.table"] }

    /// The first cell of each row is the name ("track, selected" when selected; fixture names have no commas).
    func names(in table: XCUIElement) -> [String] {
        table.tableRows.allElementsBoundByIndex.compactMap { row in
            row.cells.element(boundBy: 0).label.components(separatedBy: ", ").first
        }
    }

    func cellLabels(_ row: XCUIElement) -> [String] {
        row.cells.allElementsBoundByIndex.map(\.label)
    }

    func waitFor(_ predicate: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return predicate()
    }

    func testListsDirectoryTotalCommanderStyle() {
        XCTAssertTrue(leftTable.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 },
                      "rows=\(leftTable.tableRows.count) label=\(leftTable.label) status=\(app.staticTexts["pane.left.status"].value ?? "")")
        // No ".." row; directories first, then files; hidden files not shown; extension in its own column.
        XCTAssertEqual(names(in: leftTable), ["Alpha", "Beta", "apple pie", "notes", "song", "track"])
        XCTAssertEqual(leftTable.label, "Left pane")
        XCTAssertEqual(rightTable.label, "Right pane")
    }

    func testKeyboardNavigationAndPaneSwitch() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(.enter, modifierFlags: [])            // cursor starts on Alpha: enter it
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["Inner"] }, "\(names(in: leftTable))")
        leftTable.typeKey(.delete, modifierFlags: [])           // Backspace: parent
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        XCTAssertTrue(leftTable.tableRows.element(boundBy: 0).isSelected, "cursor returns to the folder we came from")

        leftTable.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(waitFor { (self.rightTable.value(forKey: "hasKeyboardFocus") as? Bool) == true })
    }

    func testTypeAheadJumpsToName() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeText("so")
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 4).isSelected })
    }

    func testQuickFilterAndHiddenToggle() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey("s", modifierFlags: .command)
        let field = app.searchFields["quickFilter.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeText("*.mp3;*.flac")
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["song", "track"] }, "\(names(in: leftTable))")
        field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })

        leftTable.typeKey(".", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).contains(".secret") })
    }

    func testMarkingWithSpace() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(.end, modifierFlags: [])
        leftTable.typeKey(" ", modifierFlags: [])
        let status = app.staticTexts["pane.left.status"]
        XCTAssertTrue(waitFor { (status.value as? String)?.contains("1 of 4 files, 0 of 2 folders selected") == true }, "\(status.value ?? "")")
        // The selected file's name is read with ", selected".
        XCTAssertEqual(cellLabels(leftTable.tableRows.element(boundBy: 5)).prefix(2), ["track, selected", "flac"])
    }

    func testHomeAndEndKeys() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(.end, modifierFlags: [])
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 5).isSelected })
        leftTable.typeKey(.home, modifierFlags: [])
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 0).isSelected })
    }

    func testRowsReadLikeTotalCommanderColumns() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        // A folder's empty extension cell is left out (VoiceOver would say "column 2, row 1" for it)
        // and its size reads "dir".
        let folder = cellLabels(leftTable.tableRows.element(boundBy: 0))
        XCTAssertEqual(folder.count, 4, "\(folder)")
        XCTAssertEqual(folder.prefix(2), ["Alpha", "dir"])
        XCTAssertEqual(cellLabels(leftTable.tableRows.element(boundBy: 4)).prefix(2), ["song", "mp3"])
    }

    func testBriefAndFullViews() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(XCUIKeyboardKey.F1, modifierFlags: .control)
        XCTAssertTrue(waitFor { self.leftTable.tableColumns.count == 1 })
        // Brief has no Ext column, so names include the extension.
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).contains("song.mp3") }, "\(names(in: leftTable))")
        leftTable.typeKey(XCUIKeyboardKey.F2, modifierFlags: .control)
        XCTAssertTrue(waitFor { self.leftTable.tableColumns.count == 5 })
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).contains("song") })
    }

    func testLocationsMenuOpensForCurrentPane() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.menuItems["Home"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Add Current Folder to Bookmarks"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testColumnsAreConfigurableInSettings() throws {
        XCTAssertTrue(waitFor { self.leftTable.tableColumns.count == 5 })
        leftTable.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Basil Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        let created = settings.checkBoxes["Created"]
        XCTAssertTrue(created.waitForExistence(timeout: 2), settings.debugDescription)
        created.click()
        XCTAssertTrue(waitFor { self.leftTable.tableColumns.count == 6 })
        // Audits the app with the settings window in front.
        try app.performAccessibilityAudit { issue in
            // SwiftUI's own Picker pop-up button reports "Action is missing" to the audit although
            // VoiceOver can open it (VO-Space). Verify manually with VoiceOver when changing pickers.
            // Disabled controls (e.g. "Add Column" when every column is already in the view) have no action by design.
            if issue.auditType == .action, let element = issue.element,
               element.elementType == .popUpButton || !element.isEnabled {
                return true
            }
            print("AUDIT settings: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
    }

    func testCopySettingsTab() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Basil Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        let tab = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Copying'")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 2), settings.debugDescription)
        tab.click()
        let verify = settings.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Verify copies by reading the destination back'")).firstMatch
        XCTAssertTrue(verify.waitForExistence(timeout: 2), settings.debugDescription)
        XCTAssertEqual(verify.elementType, .switch)
        XCTAssertEqual(verify.value as? Int, 0, "verification is off by default")
        XCTAssertTrue(settings.steppers["Retries when a file changes during copying"].exists, settings.debugDescription)
        try app.performAccessibilityAudit { issue in
            if issue.auditType == .action, let element = issue.element, !element.isEnabled { return true }
            print("AUDIT copy settings: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
    }

    func testMainWindowPassesAccessibilityAudit() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        XCTAssertTrue(rightTable.exists)
        try app.performAccessibilityAudit { issue in
            print("AUDIT: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
    }
}

