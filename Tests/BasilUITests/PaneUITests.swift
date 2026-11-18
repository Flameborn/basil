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
    /// Read from one snapshot: rows change while file operations run, so querying them one by one races.
    func names(in table: XCUIElement) -> [String] {
        guard let root = try? table.snapshot() else { return [] }
        var rows: [any XCUIElementSnapshot] = []
        func walk(_ s: any XCUIElementSnapshot) {
            if s.elementType == .tableRow { rows.append(s); return }
            s.children.forEach(walk)
        }
        walk(root)
        return rows.compactMap { row in
            row.children.first { $0.elementType == .cell }?.label.components(separatedBy: ", ").first
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
        // The row itself carries the whole row, read when the cursor row has VoiceOver focus.
        XCTAssertTrue(leftTable.tableRows.element(boundBy: 4).label.hasPrefix("song, mp3, "),
                      leftTable.tableRows.element(boundBy: 4).label)
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
        let secure = settings.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Secure copy and move'")).firstMatch
        XCTAssertEqual(secure.value as? Int, 0, "secure mode is off by default")
        try app.performAccessibilityAudit { issue in
            if issue.auditType == .action, let element = issue.element, !element.isEnabled { return true }
            print("AUDIT copy settings: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
    }

    func testMultiRenameWithPreviewAndUndo() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeText("so")
        leftTable.typeKey(.space, modifierFlags: [])
        leftTable.typeKey(.downArrow, modifierFlags: [])   // track
        leftTable.typeKey(.space, modifierFlags: [])
        leftTable.typeKey("m", modifierFlags: .command)

        // A modal window is a dialog to accessibility.
        let window = app.dialogs["Multi-Rename"]
        XCTAssertTrue(window.waitForExistence(timeout: 3), app.debugDescription)
        let mask = window.textFields["Name mask"]
        XCTAssertTrue(mask.exists, window.debugDescription)
        mask.typeKey("a", modifierFlags: .command)
        mask.typeText("[N] [C]")
        let preview = window.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", "song.mp3, to song 1.mp3", "song.mp3, to song 1.mp3")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 3), window.debugDescription)
        mask.typeKey(.tab, modifierFlags: [])   // ends editing: an active field editor fails the audit's parent check
        try app.performAccessibilityAudit { issue in
            // SwiftUI Menu and Picker pop-up buttons report "Action is missing" although VoiceOver opens them;
            // disabled controls have no action by design.
            if issue.auditType == .action, let element = issue.element,
               element.elementType == .popUpButton || element.elementType == .menuButton || !element.isEnabled {
                return true
            }
            print("AUDIT multi-rename: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        mask.click()
        app.typeKey(.return, modifierFlags: [])   // Return in the mask field starts, as in TC
        XCTAssertTrue(waitFor { !window.exists })
        XCTAssertTrue(waitFor { Set(self.names(in: self.leftTable)).isSuperset(of: ["song 1", "track 2"]) },
                      "\(names(in: leftTable))")

        leftTable.typeKey("m", modifierFlags: .command)
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        window.buttons["Undo Last Rename"].click()
        XCTAssertTrue(waitFor { Set(self.names(in: self.leftTable)).isSuperset(of: ["song", "track"]) },
                      "\(names(in: leftTable))")
    }

    func testMainWindowPassesAccessibilityAudit() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        XCTAssertTrue(rightTable.exists)
        try app.performAccessibilityAudit { issue in
            print("AUDIT: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
    }

    func testCommandWClosesSettings() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Basil Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitFor { !settings.exists })
        XCTAssertTrue(leftTable.exists, "Cmd+W must not close the main window")
    }

    func testSoundsAndSpeechTab() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Basil Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        let tab = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Sounds and Speech'")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 2), settings.debugDescription)
        tab.click()
        let speak = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Finished: speak'")).firstMatch
        XCTAssertTrue(speak.waitForExistence(timeout: 2), settings.debugDescription)
        try app.performAccessibilityAudit { issue in
            if issue.auditType == .action, let element = issue.element,
               element.elementType == .popUpButton || !element.isEnabled {
                return true
            }
            print("AUDIT sounds: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
    }

    /// F7 new folder, F5 copy, Shift+F6 rename, Shift+F8 delete, each through its dialog and the queue.
    func testFileOperationsWithKeyboard() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })

        leftTable.typeKey(.F7, modifierFlags: [])
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        app.typeText("Gamma\r")
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).contains("Gamma") }, "\(names(in: leftTable))")

        leftTable.typeText("so")
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 5).isSelected })
        leftTable.typeKey(.F5, modifierFlags: [])
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        XCTAssertTrue(sheet.textFields["Target folder"].exists, sheet.debugDescription)
        app.typeKey(.return, modifierFlags: [])
        if !waitFor({ self.names(in: self.rightTable) == ["song"] }) {
            let sheetText = sheet.exists ? sheet.debugDescription : "no sheet"
            leftTable.typeKey("j", modifierFlags: .command)
            let query = app.descendants(matching: .any).matching(identifier: "queue.row")
            _ = waitFor { query.allElementsBoundByIndex.allSatisfy { !$0.label.isEmpty } }
            let rows = query.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }
            XCTFail("right=\(names(in: rightTable)) queue=\(rows) sheet=\(sheetText)")
        }

        leftTable.typeKey(.F6, modifierFlags: .shift)
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        app.typeText("tune\r")   // the name without its extension is selected, so this keeps ".mp3"
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).contains("tune") }, "\(names(in: leftTable))")
        XCTAssertFalse(names(in: leftTable).contains("song"))

        leftTable.typeKey(.F8, modifierFlags: .shift)   // the cursor is on the renamed item
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        XCTAssertTrue(sheet.buttons["Delete"].exists, sheet.debugDescription)
        try app.performAccessibilityAudit { issue in
            print("AUDIT delete dialog: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        app.typeKey(.return, modifierFlags: [])
        if !waitFor({ !self.names(in: self.leftTable).contains("tune") }) {
            leftTable.typeKey("j", modifierFlags: .command)
            let query = app.descendants(matching: .any).matching(identifier: "queue.row")
            _ = waitFor { query.count > 0 }
            XCTFail("left=\(names(in: leftTable)) queue=\(query.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label })")
        }
    }

    func testF2Rereads() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(.F2, modifierFlags: [])
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
    }
}
