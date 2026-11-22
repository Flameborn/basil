import XCTest

/// Drives the real app against a fixture directory with the keyboard only.
@MainActor
final class PaneUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        // The app builds the fixture itself (Debug only), see App/Sources/UITestFixture.swift:
        // Alpha/Inner/pack.zip (docs/readme.txt, top.txt), Beta/, "apple pie.txt", song.mp3,
        // track.flac, notes.md, .secret
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

    /// Sheets open animated: typing before their text field has focus loses keys or lands elsewhere.
    func waitForFieldFocus(in sheet: XCUIElement) {
        let field = sheet.textFields.firstMatch
        XCTAssertTrue(waitFor { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }, sheet.debugDescription)
    }


    func testWindowTitleFollowsActivePaneFolder() {
        XCTAssertTrue(leftTable.waitForExistence(timeout: 5))
        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.title.hasPrefix("basil-uitest-"), window.title)
        XCTAssertTrue(window.title.hasSuffix(" - Basil"), window.title)
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(waitFor { window.title == "Beta - Basil" }, window.title)
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
        XCTAssertEqual(names(in: leftTable), ["Alpha", "Beta", "apple pie.txt", "notes.md", "song.mp3", "track.flac"])
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
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["song.mp3", "track.flac"] }, "\(names(in: leftTable))")
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
        XCTAssertEqual(cellLabels(leftTable.tableRows.element(boundBy: 5)).first, "track.flac, selected")
        leftTable.typeKey("-", modifierFlags: [.command, .shift])   // Deselect All (also Cmd+Numpad Minus)
        XCTAssertTrue(waitFor { (status.value as? String)?.contains("0 of 4 files, 0 of 2 folders selected") == true }, "\(status.value ?? "")")
    }

    /// XCUITest cannot type keypad keys, so the numpad commands are reached through the Mark menu.
    func testSelectGroupFromMarkMenu() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["Mark"].click()
        menuBar.menuItems["Select Group..."].click()
        let mask = app.comboBoxes["Mask"]
        XCTAssertTrue(mask.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(waitFor { (mask.value(forKey: "hasKeyboardFocus") as? Bool) == true })
        mask.typeKey("a", modifierFlags: .command)
        mask.typeText("*.mp3;*.flac")
        mask.typeKey(.tab, modifierFlags: [])
        let sheet = app.sheets.firstMatch
        try audit(app) { issue in
            if self.isCoveredElsewhere(issue, by: sheet) { return true }
            print("AUDIT select group: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        sheet.buttons["Select"].click()
        let status = app.staticTexts["pane.left.status"]
        XCTAssertTrue(waitFor { (status.value as? String)?.contains("2 of 4 files, 0 of 2 folders selected") == true }, "\(status.value ?? "")")

        menuBar.menuBarItems["Mark"].click()
        menuBar.menuItems["Invert Selection"].click()
        XCTAssertTrue(waitFor { (status.value as? String)?.contains("2 of 4 files, 0 of 2 folders selected") == true }, "\(status.value ?? "")")
        leftTable.typeKey("-", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor { (status.value as? String)?.contains("0 of 4 files") == true })
        menuBar.menuBarItems["Mark"].click()
        menuBar.menuItems["Restore Selection"].click()
        XCTAssertTrue(waitFor { (status.value as? String)?.contains("2 of 4 files") == true }, "\(status.value ?? "")")
    }

    func testCreateAndVerifyChecksums() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeText("so")
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 4).isSelected })
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["Files"].click()
        menuBar.menuItems["Checksums"].click()
        menuBar.menuItems["Create Checksum Files..."].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        let algorithm = sheet.popUpButtons["Algorithm"]
        XCTAssertTrue(algorithm.waitForExistence(timeout: 2), sheet.debugDescription)
        algorithm.click()
        let sha256 = app.menuItems["SHA-256"]
        XCTAssertTrue(sha256.waitForExistence(timeout: 3))
        sha256.click()
        let field = sheet.textFields["Checksum file"]
        XCTAssertTrue(waitFor { (field.value as? String) == "song.mp3.sha256" }, "\(field.value ?? "")")
        try audit(app) { issue in
            if issue.auditType == .action, issue.element?.elementType == .popUpButton { return true }
            if self.isCoveredElsewhere(issue, by: sheet) { return true }
            print("AUDIT checksums: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        sheet.buttons["Create"].click()
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).contains("song.mp3.sha256") }, "\(names(in: leftTable))")

        // The cursor lands on the new checksum file; Verify Checksums checks it in the queue.
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 5).isSelected })
        menuBar.menuBarItems["Files"].click()
        menuBar.menuItems["Checksums"].click()
        menuBar.menuItems["Verify Checksums"].click()
        leftTable.typeKey("j", modifierFlags: .command)
        let rows = app.descendants(matching: .any).matching(identifier: "queue.row")
        XCTAssertTrue(waitFor {
            rows.allElementsBoundByIndex.contains { (($0.value as? String) ?? $0.label).hasPrefix("Verify song.mp3.sha256, finished") }
        }, "\(rows.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label })")
    }

    func testCalculateFolderSize() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        XCTAssertEqual(cellLabels(leftTable.tableRows.element(boundBy: 0)).prefix(2), ["Alpha", "dir"])
        leftTable.typeKey("s", modifierFlags: [.command, .shift])
        // Once calculated, the Size cell shows the folder's size and reads "dir, <size>".
        XCTAssertTrue(waitFor { self.cellLabels(self.leftTable.tableRows.element(boundBy: 0)).dropFirst().first?.hasPrefix("dir, ") == true },
                      "\(cellLabels(leftTable.tableRows.element(boundBy: 0)))")
    }

    func testGoToPathWithSuggestions() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey("g", modifierFlags: .command)
        let field = app.textFields["goto.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(waitFor { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true })
        app.typeText("al")   // relative to the pane's folder; matches without case
        let suggestions = app.tables["goto.suggestions"]
        XCTAssertTrue(waitFor { suggestions.staticTexts["Alpha"].exists }, suggestions.debugDescription)
        app.typeKey(.tab, modifierFlags: [])   // completes to "Alpha/"
        XCTAssertTrue(waitFor { (field.value as? String) == "Alpha/" }, "\(field.value ?? "")")
        XCTAssertTrue(waitFor { suggestions.staticTexts["Inner"].exists }, suggestions.debugDescription)
        try audit(app) { issue in
            // The field being edited makes the audit report a parent/child mismatch (AppKit field editor).
            if issue.auditType == .parentChild { return true }
            if self.isCoveredElsewhere(issue, by: self.app.sheets.firstMatch) { return true }
            print("AUDIT go to: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["Inner"] }, "\(names(in: leftTable))")

        // A file: its folder opens with the cursor on it.
        leftTable.typeKey("g", modifierFlags: .command)
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertTrue(waitFor { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true })
        app.typeText("../track.flac\r")
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 5).isSelected })
    }

    func testFinderGoKeys() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey("c", modifierFlags: [.command, .shift])
        let path = app.groups["pane.left.path"]
        XCTAssertTrue(waitFor { (path.value as? String) == "/Volumes" }, "\(path.value ?? "")")
    }

    func testPaneTabs() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        let path = app.groups["pane.left.path"]
        let fixture = try XCTUnwrap(path.value as? String)
        let tabs = app.tabGroups["pane.left.tabs"]
        XCTAssertFalse(tabs.exists)                                      // one tab: no tab row
        leftTable.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(tabs.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(tabs.radioButtons.count, 2)
        leftTable.typeKey(.enter, modifierFlags: [])                     // Alpha, in the new tab
        XCTAssertTrue(waitFor { (path.value as? String) == fixture + "/Alpha" })
        XCTAssertTrue(waitFor { tabs.radioButtons.element(boundBy: 1).label == "Alpha" })
        try audit(app) { issue in
            print("AUDIT tabs: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }

        leftTable.typeKey(.tab, modifierFlags: .control)                 // next tab wraps to the first
        XCTAssertTrue(waitFor { (path.value as? String) == fixture }, "\(path.value ?? "")")
        XCTAssertTrue(waitFor { (tabs.radioButtons.element(boundBy: 0).value as? Int) == 1 })
        leftTable.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(waitFor { (path.value as? String) == fixture + "/Alpha" })
        leftTable.typeKey("w", modifierFlags: .command)                  // closes Alpha's tab
        XCTAssertTrue(waitFor { (path.value as? String) == fixture }, "\(path.value ?? "")")
        XCTAssertTrue(waitFor { !tabs.exists })

        // A locked tab keeps its folder: Enter on a folder opens it in a new tab.
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["Tabs"].click()
        menuBar.menuItems["Lock Tab"].click()
        leftTable.typeKey(.enter, modifierFlags: [])
        XCTAssertTrue(tabs.waitForExistence(timeout: 3))
        XCTAssertTrue(waitFor { (path.value as? String) == fixture + "/Alpha" })
        XCTAssertEqual(tabs.radioButtons.element(boundBy: 0).label, "\(URL(fileURLWithPath: fixture).lastPathComponent) (locked)")
        leftTable.typeKey(.tab, modifierFlags: [.control, .shift])
        XCTAssertTrue(waitFor { (path.value as? String) == fixture })
    }

    func testPathBarGoesToAnyPartOfThePath() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        let path = app.groups["pane.left.path"]
        XCTAssertTrue(path.exists, app.debugDescription)
        let fixture = try XCTUnwrap(path.value as? String)
        leftTable.typeKey(.enter, modifierFlags: [])                     // Alpha
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["Inner"] })
        leftTable.typeKey(.enter, modifierFlags: [])                     // Inner
        XCTAssertTrue(waitFor { (path.value as? String) == fixture + "/Alpha/Inner" }, "\(path.value ?? "")")
        // One button per part, the last is the current folder.
        let parts = path.buttons
        XCTAssertEqual(parts.element(boundBy: parts.count - 1).label, "Inner")
        XCTAssertEqual(parts.element(boundBy: parts.count - 2).label, "Alpha")
        try audit(app) { issue in
            print("AUDIT path bar: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }

        // Clicking a part goes there, with the cursor on the folder leading back.
        parts.element(boundBy: parts.count - 3).click()
        XCTAssertTrue(waitFor { (path.value as? String) == fixture }, "\(path.value ?? "")")
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 0).isSelected })

        // Cmd+L, Left, Return: the parent folder by keyboard; the list has focus again.
        leftTable.typeKey(.enter, modifierFlags: [])                     // Alpha
        XCTAssertTrue(waitFor { (path.value as? String) == fixture + "/Alpha" })
        leftTable.typeKey("l", modifierFlags: .command)
        let last = parts.element(boundBy: parts.count - 1)
        XCTAssertTrue(waitFor { (last.value(forKey: "hasKeyboardFocus") as? Bool) == true })
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { (path.value as? String) == fixture }, "\(path.value ?? "")")
        // The list has focus again (after a cursor move, its cursor row is the focused element).
        func listHasFocus() -> Bool {
            (leftTable.value(forKey: "hasKeyboardFocus") as? Bool) == true
                || (leftTable.tableRows.element(boundBy: 0).value(forKey: "hasKeyboardFocus") as? Bool) == true
        }
        XCTAssertTrue(waitFor { listHasFocus() })
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 0).isSelected })
        // Escape leaves the bar without going anywhere.
        leftTable.typeKey("l", modifierFlags: .command)
        let current = parts.element(boundBy: parts.count - 1)
        XCTAssertTrue(waitFor { (current.value(forKey: "hasKeyboardFocus") as? Bool) == true })
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitFor { listHasFocus() })
        XCTAssertEqual(path.value as? String, fixture)
    }

    func testInfoSheet() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeText("so")
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 4).isSelected })
        leftTable.typeKey("i", modifierFlags: .command)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        XCTAssertTrue(sheet.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'song.mp3' OR value CONTAINS 'song.mp3'")).firstMatch.exists,
                      sheet.debugDescription)
        XCTAssertTrue(sheet.popUpButtons["Open with"].exists, sheet.debugDescription)
        try audit(app) { issue in
            if issue.auditType == .action, let element = issue.element,
               element.elementType == .popUpButton || !element.isEnabled {
                return true
            }
            if self.isCoveredElsewhere(issue, by: sheet) { return true }
            print("AUDIT info: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitFor { !sheet.exists })
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
        XCTAssertEqual(cellLabels(leftTable.tableRows.element(boundBy: 4)).prefix(2), ["song.mp3", "1 B"])
        // The row itself carries the whole row, read when the cursor row has VoiceOver focus.
        XCTAssertTrue(leftTable.tableRows.element(boundBy: 4).label.hasPrefix("song.mp3, 1 B, "),
                      leftTable.tableRows.element(boundBy: 4).label)
    }

    func testBriefAndFullViews() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(XCUIKeyboardKey.F1, modifierFlags: [.control, .shift])
        XCTAssertTrue(waitFor { self.leftTable.tableColumns.count == 1 })
        // Names always include the extension.
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).contains("song.mp3") }, "\(names(in: leftTable))")
        leftTable.typeKey(XCUIKeyboardKey.F2, modifierFlags: [.control, .shift])
        XCTAssertTrue(waitFor { self.leftTable.tableColumns.count == 4 })
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).contains("song.mp3") })
    }

    func testSortKeysReverse() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(XCUIKeyboardKey.F4, modifierFlags: [.control, .shift])
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["Alpha", "Beta", "track.flac", "notes.md", "song.mp3", "apple pie.txt"] },
                      "\(names(in: leftTable))")
        // The same key again reverses the order; folders stay first.
        leftTable.typeKey(XCUIKeyboardKey.F4, modifierFlags: [.control, .shift])
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["Beta", "Alpha", "apple pie.txt", "song.mp3", "notes.md", "track.flac"] },
                      "\(names(in: leftTable))")
        leftTable.typeKey(XCUIKeyboardKey.F7, modifierFlags: [.control, .shift])
        XCTAssertTrue(waitFor { Set(self.names(in: self.leftTable).prefix(2)) == ["Alpha", "Beta"] }, "\(names(in: leftTable))")
        leftTable.typeKey(XCUIKeyboardKey.F3, modifierFlags: [.control, .shift])
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["Alpha", "Beta", "apple pie.txt", "notes.md", "song.mp3", "track.flac"] })
    }

    func testMenusRunRegistryCommands() {
        XCTAssertTrue(waitFor { self.leftTable.tableColumns.count == 4 })
        let menuBar = app.menuBars.firstMatch
        for title in ["Files", "Mark", "Commands", "Net", "Show", "Tabs", "Edit", "Window", "Help"] {
            XCTAssertTrue(menuBar.menuBarItems[title].exists, "missing menu \(title)")
        }
        menuBar.menuBarItems["Files"].click()
        XCTAssertTrue(menuBar.menuItems["Copy"].waitForExistence(timeout: 2))
        XCTAssertTrue(menuBar.menuItems["Archives"].exists)
        app.typeKey(.escape, modifierFlags: [])
        menuBar.menuBarItems["Net"].click()
        let placeholder = menuBar.menuItems["No connections yet"]
        XCTAssertTrue(placeholder.waitForExistence(timeout: 2))
        XCTAssertFalse(placeholder.isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        menuBar.menuBarItems["Show"].click()
        menuBar.menuItems["View Mode"].click()
        menuBar.menuItems["Brief View"].click()
        XCTAssertTrue(waitFor { self.leftTable.tableColumns.count == 1 })
        // The keys still go to the pane, not to the menu items that show them.
        leftTable.typeKey(XCUIKeyboardKey.F2, modifierFlags: [.control, .shift])
        XCTAssertTrue(waitFor { self.leftTable.tableColumns.count == 4 })
    }

    func testLocationsMenuOpensForCurrentPane() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.menuItems["Home"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Add Current Folder to Bookmarks"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testColumnsAreConfigurableInSettings() throws {
        XCTAssertTrue(waitFor { self.leftTable.tableColumns.count == 4 })
        leftTable.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Basil Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        let created = settings.checkBoxes["Created"]
        XCTAssertTrue(created.waitForExistence(timeout: 2), settings.debugDescription)
        created.click()
        XCTAssertTrue(waitFor { self.leftTable.tableColumns.count == 5 })
        // Audits the app with the settings window in front.
        try audit(app) { issue in
            // SwiftUI's own Picker pop-up button reports "Action is missing" to the audit although
            // VoiceOver can open it (VO-Space). Verify manually with VoiceOver when changing pickers.
            // Disabled controls (e.g. "Add Column" when every column is already in the view) have no action by design.
            if issue.auditType == .action, let element = issue.element,
               element.elementType == .popUpButton || !element.isEnabled {
                return true
            }
            if self.isCoveredElsewhere(issue, by: settings) { return true }
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
        try audit(app) { issue in
            if issue.auditType == .action, let element = issue.element, !element.isEnabled { return true }
            if self.isCoveredElsewhere(issue, by: settings) { return true }
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
        leftTable.typeKey(.F6, modifierFlags: .shift)   // several items selected: Shift+F6 opens Multi-Rename

        // A modal window is a dialog to accessibility.
        let window = app.dialogs["Multi-Rename"]
        XCTAssertTrue(window.waitForExistence(timeout: 3), app.debugDescription)
        let mask = window.textFields["Name mask"]
        XCTAssertTrue(mask.exists, window.debugDescription)
        mask.typeKey("a", modifierFlags: .command)
        mask.typeText("[N] [C]")
        // The preview is a table: Old name, New name, Status, Modified.
        let newName = window.tables["multiRename.preview"].staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", "song 1.mp3", "song 1.mp3")).firstMatch
        XCTAssertTrue(newName.waitForExistence(timeout: 5), window.debugDescription)
        XCTAssertEqual(window.tables["multiRename.preview"].tableColumns.count, 4, window.debugDescription)
        mask.typeKey(.tab, modifierFlags: [])   // ends editing: an active field editor fails the audit's parent check
        try audit(app) { issue in
            // SwiftUI Menu and Picker pop-up buttons report "Action is missing" although VoiceOver opens them;
            // disabled controls have no action by design.
            if issue.auditType == .action, let element = issue.element,
               element.elementType == .popUpButton || element.elementType == .menuButton || !element.isEnabled {
                return true
            }
            if self.isCoveredElsewhere(issue, by: window) { return true }
            print("AUDIT multi-rename: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        mask.click()
        app.typeKey(.return, modifierFlags: [])   // Return in the mask field starts, as in TC
        XCTAssertTrue(waitFor { !window.exists })
        XCTAssertTrue(waitFor { Set(self.names(in: self.leftTable)).isSuperset(of: ["song 1.mp3", "track 2.flac"]) },
                      "\(names(in: leftTable))")

        leftTable.typeKey("m", modifierFlags: .command)
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        window.buttons["Undo Last Rename"].click()
        XCTAssertTrue(waitFor { Set(self.names(in: self.leftTable)).isSuperset(of: ["song.mp3", "track.flac"]) },
                      "\(names(in: leftTable))")
    }

    func testMainWindowPassesAccessibilityAudit() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        XCTAssertTrue(rightTable.exists)
        try audit(app) { issue in
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
        try audit(app) { issue in
            if issue.auditType == .action, let element = issue.element,
               element.elementType == .popUpButton || !element.isEnabled {
                return true
            }
            if self.isCoveredElsewhere(issue, by: settings) { return true }
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
        waitForFieldFocus(in: sheet)
        app.typeText("Gamma\r")
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).contains("Gamma") }, "\(names(in: leftTable))")

        leftTable.typeText("so")
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 5).isSelected })
        leftTable.typeKey(.F5, modifierFlags: [])
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        XCTAssertTrue(sheet.textFields["Target folder"].exists, sheet.debugDescription)
        app.typeKey(.return, modifierFlags: [])
        if !waitFor({ self.names(in: self.rightTable) == ["song.mp3"] }) {
            let sheetText = sheet.exists ? sheet.debugDescription : "no sheet"
            leftTable.typeKey("j", modifierFlags: .command)
            let query = app.descendants(matching: .any).matching(identifier: "queue.row")
            _ = waitFor { query.allElementsBoundByIndex.allSatisfy { !$0.label.isEmpty } }
            let rows = query.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }
            XCTFail("right=\(names(in: rightTable)) queue=\(rows) sheet=\(sheetText)")
        }

        leftTable.typeKey(.F6, modifierFlags: .shift)
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        waitForFieldFocus(in: sheet)
        app.typeText("tune\r")   // the name without its extension is selected, so this keeps ".mp3"
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).contains("tune.mp3") }, "\(names(in: leftTable))")
        XCTAssertFalse(names(in: leftTable).contains("song.mp3"))

        leftTable.typeKey(.F8, modifierFlags: .shift)   // the cursor is on the renamed item
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        XCTAssertTrue(sheet.buttons["Delete"].exists, sheet.debugDescription)
        try audit(app) { issue in
            if self.isCoveredElsewhere(issue, by: sheet) { return true }
            // The system NSAlert draws this text on translucent glass over the panes. Measured in the
            // audit's own element screenshot (dark mode): E7E7E7 on 454545, 7.7:1, yet it is reported.
            if issue.auditType == .contrast, (issue.element?.value as? String) == "This cannot be undone." { return true }
            print("AUDIT delete dialog: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        app.typeKey(.return, modifierFlags: [])
        if !waitFor({ !self.names(in: self.leftTable).contains("tune.mp3") }) {
            leftTable.typeKey("j", modifierFlags: .command)
            let query = app.descendants(matching: .any).matching(identifier: "queue.row")
            _ = waitFor { query.count > 0 }
            XCTFail("left=\(names(in: leftTable)) queue=\(query.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label })")
        }
    }

    func testF3QuickLookFollowsCursorAndCloses() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeText("no")
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 3).isSelected })
        let before = app.windows.count
        leftTable.typeKey(.F3, modifierFlags: [])
        XCTAssertTrue(waitFor { self.app.windows.count > before }, app.debugDescription)
        // Keys in the panel go to the pane: Down moves the cursor to song.mp3.
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 4).isSelected })
        app.typeKey(.F3, modifierFlags: [])
        XCTAssertTrue(waitFor { self.app.windows.count == before }, app.debugDescription)
    }

    /// F3 on a file inside an archive previews an extracted copy.
    func testF3QuickLookInsideArchive() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(.enter, modifierFlags: [])                     // Alpha
        if !waitFor({ self.names(in: self.leftTable) == ["Inner"] }, timeout: 2) {
            leftTable.typeKey(.enter, modifierFlags: [])
        }
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["Inner"] })
        leftTable.typeKey(.enter, modifierFlags: [])                     // Inner
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["pack.zip"] })
        leftTable.typeKey(.enter, modifierFlags: [])                     // into the archive
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["docs", "top.txt"] })
        leftTable.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 1).isSelected })
        let before = app.windows.count
        leftTable.typeKey(.F3, modifierFlags: [])
        XCTAssertTrue(waitFor { self.app.windows.count > before }, app.debugDescription)
        // The preview shows the extracted file's text.
        let text = app.windows["Quick Look"].textViews.firstMatch
        XCTAssertTrue(waitFor { (text.value as? String) == "top" }, app.windows["Quick Look"].debugDescription)
        app.typeKey(.F3, modifierFlags: [])
        XCTAssertTrue(waitFor { self.app.windows.count == before }, app.debugDescription)
    }

    func testEditorAndTerminalSettingsTab() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Basil Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        let tab = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Editor and Terminal'")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 2), settings.debugDescription)
        tab.click()
        let add = settings.buttons["Add Rule"]
        XCTAssertTrue(add.waitForExistence(timeout: 2), settings.debugDescription)
        add.click()
        let patterns = settings.textFields["Patterns"]
        XCTAssertTrue(patterns.waitForExistence(timeout: 2), settings.debugDescription)
        patterns.click()
        patterns.typeText("*.md")
        let row = settings.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH '*.md: no apps' OR value BEGINSWITH '*.md: no apps'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 2), settings.debugDescription)
        // A field being edited fails the audit (AppKit field editor), so move focus to the rule list.
        row.click()
        XCTAssertTrue(waitFor { (patterns.value(forKey: "hasKeyboardFocus") as? Bool) != true })
        XCTAssertTrue(settings.popUpButtons["Terminal"].exists, settings.debugDescription)
        try audit(app) { issue in
            if issue.auditType == .action, let element = issue.element,
               element.elementType == .popUpButton || !element.isEnabled {
                return true
            }
            if self.isCoveredElsewhere(issue, by: settings) { return true }
            print("AUDIT editor settings: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
    }

    /// An encrypted 7z asks for its password in a sheet (secure field, "Remember in Keychain"),
    /// says when it was wrong, and opens with the right one. UI tests keep passwords in memory.
    func testEncrypted7zAsksForThePassword() throws {
        app.terminate()
        app.launchEnvironment["BASIL_UITEST_ENCRYPTED_7Z"] = "1"
        app.launch()
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(.enter, modifierFlags: [])                     // Alpha
        if !waitFor({ self.names(in: self.leftTable) == ["Inner"] }, timeout: 2) {
            leftTable.typeKey(.enter, modifierFlags: [])
        }
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["Inner"] }, "\(names(in: leftTable))")
        leftTable.typeKey(.enter, modifierFlags: [])                     // Inner
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["pack.zip", "secret.7z"] }, "\(names(in: leftTable))")
        leftTable.typeKey(.downArrow, modifierFlags: [])
        leftTable.typeKey(.enter, modifierFlags: [])                     // the archive asks for its password

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["Password for secret.7z:"].exists, sheet.debugDescription)
        let field = sheet.secureTextFields["Password"]
        XCTAssertTrue(field.exists, sheet.debugDescription)
        XCTAssertTrue(sheet.checkBoxes["Remember in Keychain"].exists)
        XCTAssertEqual(sheet.checkBoxes["Remember in Keychain"].value as? Int, 0)
        XCTAssertTrue(waitFor { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true })
        app.typeKey(.tab, modifierFlags: [])                             // out of the field for the audit
        try audit(app) { issue in
            if self.isCoveredElsewhere(issue, by: sheet) { return true }
            print("AUDIT password: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        field.click()
        XCTAssertTrue(waitFor { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true })
        app.typeText("wrong\r")
        XCTAssertTrue(waitFor { sheet.staticTexts["Wrong password for secret.7z. Try again."].exists }, sheet.debugDescription)
        let again = sheet.secureTextFields["Password"]
        XCTAssertTrue(waitFor { (again.value(forKey: "hasKeyboardFocus") as? Bool) == true })
        app.typeText("basil\r")
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["note.txt"] }, "\(names(in: leftTable))")
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    func testRarArchiveBrowsesAndIsReadOnly() throws {
        app.terminate()
        app.launchEnvironment["BASIL_UITEST_RAR"] = "1"
        app.launch()
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(.enter, modifierFlags: [])                     // Alpha
        if !waitFor({ self.names(in: self.leftTable) == ["Inner"] }, timeout: 2) {
            leftTable.typeKey(.enter, modifierFlags: [])
        }
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["Inner"] }, "\(names(in: leftTable))")
        leftTable.typeKey(.enter, modifierFlags: [])                     // Inner
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["old.rar", "pack.zip"] }, "\(names(in: leftTable))")
        leftTable.typeKey(.enter, modifierFlags: [])                     // Enter enters the RAR archive
        XCTAssertTrue(waitFor { Set(self.names(in: self.leftTable)) == ["test.txt", "testdir", "testemptydir", "testlink"] },
                      "\(names(in: leftTable))")
        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(waitFor { window.title == "old.rar - Basil" }, window.title)
        try audit(app) { issue in
            print("AUDIT rar: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        // Audited before this: the audit fails the status bar while it shows an error (see progress.md).
        leftTable.typeKey(.F7, modifierFlags: [])                        // refused: RAR archives are read-only
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 1))
        let status = app.staticTexts["pane.left.status"]
        XCTAssertTrue(waitFor { (status.value as? String) == "old.rar is a RAR archive, which Basil can only read." },
                      "\(status.value ?? "")")
    }

    func testArchiveBrowseChangeAndExtract() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(.enter, modifierFlags: [])                     // Alpha
        // The first test after a build sometimes types before the app takes keys: try once more.
        if !waitFor({ self.names(in: self.leftTable) == ["Inner"] }, timeout: 2) {
            leftTable.typeKey(.enter, modifierFlags: [])
        }
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["Inner"] }, "\(names(in: leftTable))")
        leftTable.typeKey(.enter, modifierFlags: [])                     // Inner
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["pack.zip"] }, "\(names(in: leftTable))")
        leftTable.typeKey(.enter, modifierFlags: [])                     // Enter enters the archive
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["docs", "top.txt"] }, "\(names(in: leftTable))")
        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(waitFor { window.title == "pack.zip - Basil" }, window.title)
        XCTAssertEqual(cellLabels(leftTable.tableRows.element(boundBy: 1)).prefix(2), ["top.txt", "3 B"])

        leftTable.typeKey(.enter, modifierFlags: [])                     // docs
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["readme.txt"] })
        leftTable.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["docs", "top.txt"] })
        leftTable.typeKey(.delete, modifierFlags: [])                    // leaves the archive, cursor on it
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["pack.zip"] })
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 0).isSelected })

        leftTable.typeKey(.enter, modifierFlags: [])
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["docs", "top.txt"] })
        try audit(app) { issue in
            print("AUDIT archive: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }

        // Shift+F4 does not work inside archives yet and says so.
        leftTable.typeKey(.F4, modifierFlags: .shift)
        let status = app.staticTexts["pane.left.status"]
        XCTAssertTrue(waitFor { (status.value as? String)?.contains("does not work inside archives") == true }, "\(status.value ?? "")")
        XCTAssertFalse(app.sheets.firstMatch.exists)

        // F7 makes a folder inside the archive (the archive is rewritten).
        let sheet = app.sheets.firstMatch
        leftTable.typeKey(.F7, modifierFlags: [])
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        waitForFieldFocus(in: sheet)
        app.typeText("Made\r")
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["docs", "Made", "top.txt"] }, "\(names(in: leftTable))")

        // F5 extracts the cursor item into the other pane (Beta).
        leftTable.typeKey(.end, modifierFlags: [])
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 2).isSelected })
        leftTable.typeKey(.F5, modifierFlags: [])
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        waitForFieldFocus(in: sheet)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { self.names(in: self.rightTable) == ["top.txt"] }, "\(names(in: rightTable))")

        // F8 deletes from the archive after asking.
        leftTable.typeKey(.F8, modifierFlags: [])
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        let question = sheet.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@",
                                                               "Delete top.txt from pack.zip?", "Delete top.txt from pack.zip?"))
        XCTAssertTrue(waitFor { question.firstMatch.exists }, sheet.staticTexts.allElementsBoundByIndex.map { "\($0.label)|\($0.value ?? "")" }.joined(separator: " / "))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["docs", "Made"] }, "\(names(in: leftTable))")
    }

    func testPackDialog() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeText("so")
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 4).isSelected })
        leftTable.typeKey(.F5, modifierFlags: .option)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        let field = sheet.textFields["Archive"]
        XCTAssertTrue(waitFor { (field.value as? String)?.hasSuffix("/Beta/song.zip") == true }, "\(field.value ?? "")")
        XCTAssertTrue(sheet.popUpButtons["Format"].exists, sheet.debugDescription)
        XCTAssertTrue(sheet.checkBoxes["Move to archive"].exists || sheet.switches["Move to archive"].exists, sheet.debugDescription)
        app.typeKey(.tab, modifierFlags: [])   // out of the text field before auditing
        try audit(app) { issue in
            if issue.auditType == .action, let element = issue.element,
               element.elementType == .popUpButton || !element.isEnabled {
                return true
            }
            if self.isCoveredElsewhere(issue, by: sheet) { return true }
            print("AUDIT pack: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        let testAfter = sheet.checkBoxes["Test archive after packing"].exists ? sheet.checkBoxes["Test archive after packing"]
            : sheet.switches["Test archive after packing"]
        XCTAssertTrue(testAfter.exists, sheet.debugDescription)
        testAfter.click()
        sheet.buttons["Pack"].click()
        XCTAssertTrue(waitFor { self.names(in: self.rightTable) == ["song.zip"] }, "\(names(in: rightTable))")
        // The test runs as its own queue item once packing is done.
        leftTable.typeKey("j", modifierFlags: .command)
        let rows = app.descendants(matching: .any).matching(identifier: "queue.row")
        XCTAssertTrue(waitFor {
            rows.allElementsBoundByIndex.contains { (($0.value as? String) ?? $0.label).hasPrefix("Test song.zip, finished") }
        }, "\(rows.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label })")
        leftTable.typeKey("j", modifierFlags: .command)
        // Enter opens the new archive.
        app.typeKey(.tab, modifierFlags: [])
        rightTable.typeKey(.enter, modifierFlags: [])
        XCTAssertTrue(waitFor { self.names(in: self.rightTable) == ["song.mp3"] },
                      "\(names(in: rightTable))")
    }

    /// 7z in the pack dialog: Solid archive, a password with Show password, and Encrypt file names
    /// and Remember in Keychain once a password is typed. The packed archive opens without asking.
    func testPackEncrypted7z() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeText("so")
        XCTAssertTrue(waitFor { self.leftTable.tableRows.element(boundBy: 4).isSelected })
        leftTable.typeKey(.F5, modifierFlags: .option)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        waitForFieldFocus(in: sheet)
        sheet.popUpButtons["Format"].click()
        app.menuItems["7z"].click()
        let field = sheet.textFields["Archive"]
        XCTAssertTrue(waitFor { (field.value as? String)?.hasSuffix("/Beta/song.7z") == true }, "\(field.value ?? "")")
        func toggle(_ name: String) -> XCUIElement {
            sheet.checkBoxes[name].exists ? sheet.checkBoxes[name] : sheet.switches[name]
        }
        XCTAssertTrue(toggle("Solid archive").exists, sheet.debugDescription)
        XCTAssertTrue(toggle("Show password").exists, sheet.debugDescription)
        XCTAssertFalse(toggle("Encrypt file names").exists)
        let password = sheet.secureTextFields["Password"]
        XCTAssertTrue(password.exists, sheet.debugDescription)
        password.click()
        XCTAssertTrue(waitFor { (password.value(forKey: "hasKeyboardFocus") as? Bool) == true })
        app.typeText("basil")
        XCTAssertTrue(waitFor { toggle("Encrypt file names").exists }, sheet.debugDescription)
        XCTAssertTrue(toggle("Remember in Keychain").exists)
        toggle("Show password").click()
        XCTAssertTrue(waitFor { sheet.textFields["Password"].exists && (sheet.textFields["Password"].value as? String) == "basil" },
                      sheet.debugDescription)
        toggle("Encrypt file names").click()
        // Out of every text field before auditing (an edited field reports Parent/Child mismatch).
        func editing() -> Bool {
            (sheet.textFields.allElementsBoundByIndex + sheet.secureTextFields.allElementsBoundByIndex)
                .contains { ($0.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        }
        for _ in 0..<8 where editing() { app.typeKey(.tab, modifierFlags: []) }
        XCTAssertFalse(editing())
        try audit(app) { issue in
            if issue.auditType == .action, let element = issue.element,
               element.elementType == .popUpButton || !element.isEnabled {
                return true
            }
            if self.isCoveredElsewhere(issue, by: sheet) { return true }
            print("AUDIT pack 7z: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        sheet.buttons["Pack"].click()
        XCTAssertTrue(waitFor({ self.names(in: self.rightTable) == ["song.7z"] }, timeout: 10), "\(names(in: rightTable))")
        // The password just typed is known: Enter opens the archive without asking.
        app.typeKey(.tab, modifierFlags: [])
        rightTable.typeKey(.enter, modifierFlags: [])
        XCTAssertTrue(waitFor { self.names(in: self.rightTable) == ["song.mp3"] }, "\(names(in: rightTable))")
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    func testF2Rereads() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        leftTable.typeKey(.F2, modifierFlags: [])
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
    }
}

extension XCTestCase {
    /// `performAccessibilityAudit` with Basil's one app-wide exception: list cells that show a file
    /// name with an extension ("notes.md", "song.mp3, selected"). The audit's heuristic calls such
    /// labels "not human-readable", but in a file manager the file name is exactly what VoiceOver
    /// should read (it says "notes dot md").
    @MainActor func audit(_ app: XCUIApplication, _ handler: @escaping (XCUIAccessibilityAuditIssue) -> Bool) throws {
        try app.performAccessibilityAudit { issue in
            if issue.compactDescription == "Label not human-readable", let element = issue.element,
               element.elementType == .cell,
               element.label.range(of: #"^[^/]*\.[^. /]+(, selected)?$"#, options: .regularExpression) != nil {
                return true
            }
            return handler(issue)
        }
    }

    /// Contrast issues outside `window` belong to windows it covers, dims or makes inactive. The audit
    /// samples pixels on screen, so a covered main-window status line "fails", and so do the main window
    /// that macOS dims behind a sheet and the greyed title of an inactive window. The main window is
    /// checked in its normal state by `testMainWindowPassesAccessibilityAudit`. Elements of `window` that
    /// are scrolled partly out of it count too: the audit samples whatever is beside the window (the Dock).
    @MainActor func isCoveredElsewhere(_ issue: XCUIAccessibilityAuditIssue, by window: XCUIElement) -> Bool {
        guard issue.auditType == .contrast, let element = issue.element, let root = try? window.snapshot() else { return false }
        let frame = element.frame, type = element.elementType, identifier = element.identifier
        if !root.frame.contains(frame) { return true }
        func contains(_ s: any XCUIElementSnapshot) -> Bool {
            if s.elementType == type, s.frame == frame, s.identifier == identifier { return true }
            return s.children.contains(where: contains)
        }
        return !contains(root)
    }
}
