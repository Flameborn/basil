import XCTest

/// Find Files (Option+F7): results in the window, Go to File, Show in Pane and back.
extension PaneUITests {
    var findWindow: XCUIElement { app.windows["Find Files"] }

    func openFindFiles(line: UInt = #line) -> XCUIElement {
        leftTable.typeKey(.F7, modifierFlags: .option)
        let window = findWindow
        XCTAssertTrue(window.waitForExistence(timeout: 3), line: line)
        let name = window.comboBoxes["find.name"]
        XCTAssertTrue(waitFor { (name.value(forKey: "hasKeyboardFocus") as? Bool) == true }, line: line)
        return window
    }

    func findStatus(_ window: XCUIElement) -> String { window.staticTexts["find.status"].value as? String ?? "" }

    func testFindFilesShowsResultsInThePane() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        var window = openFindFiles()
        XCTAssertTrue((window.textFields["find.folder"].value as? String ?? "").contains("basil-uitest-"))
        window.comboBoxes["find.name"].typeText("*.md;*.zip;*.mp3\r")
        XCTAssertTrue(waitFor { self.findStatus(window).hasPrefix("Found 3 items") }, findStatus(window))
        let results = window.tables["find.results"]
        XCTAssertEqual(results.tableRows.count, 3)
        let labels = results.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains { $0.hasPrefix("pack.zip, ") && $0.contains("in Alpha/Inner") }, "\(labels)")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        try audit(app) { issue in
            if issue.auditType == .action, let element = issue.element, element.elementType == .popUpButton || !element.isEnabled {
                return true
            }
            if self.isCoveredElsewhere(issue, by: window) { return true }
            print("AUDIT find files: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }

        // Show in Pane: the results become the pane's folder; Backspace goes back.
        window.buttons["Show in Pane"].click()
        XCTAssertTrue(waitFor { !window.exists })
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).sorted() == ["notes.md", "pack.zip", "song.mp3"] }, "\(names(in: leftTable))")
        XCTAssertTrue(waitFor { self.app.windows.element(boundBy: 0).title == "Search results - Basil" }, app.windows.element(boundBy: 0).title)
        let row = leftTable.tableRows.allElementsBoundByIndex.first { $0.cells.firstMatch.label.hasPrefix("pack.zip") }
        XCTAssertEqual(row?.cells.firstMatch.label, "pack.zip, in Alpha/Inner")
        // F3 previews a found file (the real one).
        let before = app.windows.count
        leftTable.typeKey(.home, modifierFlags: [])
        leftTable.typeKey(.F3, modifierFlags: [])
        XCTAssertTrue(waitFor { self.app.windows.count > before }, app.debugDescription)
        app.typeKey(.F3, modifierFlags: [])
        XCTAssertTrue(waitFor { self.app.windows.count == before }, app.debugDescription)
        // Nothing can be created in search results.
        leftTable.typeKey(.F7, modifierFlags: [])
        XCTAssertTrue(waitFor { (self.app.staticTexts["pane.left.status"].value as? String ?? "").contains("Search results only list") })
        leftTable.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 }, "\(names(in: leftTable))")

        // Go to File: the pane goes to the item's folder with the cursor on it.
        window = openFindFiles()
        XCTAssertEqual(window.tables["find.results"].tableRows.count, 3)
        window.comboBoxes["find.name"].typeKey("a", modifierFlags: .command)
        window.comboBoxes["find.name"].typeText("pack\r")
        XCTAssertTrue(waitFor { self.findStatus(window).hasPrefix("Found 1 item") },
                      "\(findStatus(window)), name: \(window.comboBoxes["find.name"].value ?? "")")
        // The results list has the focus once the search is done.
        window.tables["find.results"].typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { !window.exists })
        XCTAssertTrue(waitFor { self.app.windows.element(boundBy: 0).title == "Inner - Basil" }, app.windows.element(boundBy: 0).title)
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["pack.zip"] }, "\(names(in: leftTable))")
    }

    func testFindFilesSearchesText() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        let window = openFindFiles()
        window.comboBoxes["find.name"].typeText("*.md")
        let text = window.comboBoxes["find.text"]
        text.click()
        text.typeText("X\r")
        XCTAssertTrue(waitFor { self.findStatus(window).hasPrefix("Found 1 item") }, findStatus(window))
        window.checkBoxes["Files not containing the text"].click()
        text.click()
        text.typeText("\r")
        // Nothing found: the focus stays in the field.
        XCTAssertTrue(waitFor { self.findStatus(window).hasPrefix("Nothing found") }, findStatus(window))
        window.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitFor { !window.exists })
    }
}

extension PaneUITests {
    /// UI tests index the fixture; Automatic uses the index for names and walks for text.
    func testFindFilesUsesTheIndexForNames() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        let window = openFindFiles()
        window.comboBoxes["find.name"].typeText("*.flac\r")
        XCTAssertTrue(waitFor({ self.findStatus(window).hasSuffix("with Basil's index") }, timeout: 10), findStatus(window))
        XCTAssertTrue(findStatus(window).hasPrefix("Found 1 item"), findStatus(window))
        let name = window.comboBoxes["find.name"]
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("*.md")
        let text = window.comboBoxes["find.text"]
        text.click()
        text.typeText("x\r")
        XCTAssertTrue(waitFor { self.findStatus(window).hasSuffix("with Live folder walk") }, findStatus(window))
        window.typeKey(.escape, modifierFlags: [])
    }
}

extension PaneUITests {
    /// Multi-Rename works in search results (like TC's feed list); renamed items stay listed.
    func testMultiRenameInSearchResults() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        let window = openFindFiles()
        window.comboBoxes["find.name"].typeText("*.zip;*.mp3\r")
        XCTAssertTrue(waitFor { self.findStatus(window).hasPrefix("Found 2 items") }, findStatus(window))
        window.buttons["Show in Pane"].click()
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).sorted() == ["pack.zip", "song.mp3"] }, "\(names(in: leftTable))")
        leftTable.typeKey("a", modifierFlags: .command)
        leftTable.typeKey("m", modifierFlags: .command)
        let rename = app.dialogs["Multi-Rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        let mask = rename.textFields["Name mask"]
        // The tool opens once the items' folders are read: wait for the mask to have the focus.
        XCTAssertTrue(waitFor { (mask.value(forKey: "hasKeyboardFocus") as? Bool) == true })
        mask.typeKey("a", modifierFlags: .command)
        mask.typeText("[N]-x")
        let preview = rename.tables["multiRename.preview"]
        for name in ["pack-x.zip", "song-x.mp3"] {
            let cell = preview.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", name, name)).firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 5), "\(preview.staticTexts.allElementsBoundByIndex.map { "\($0.label)|\($0.value ?? "")" })")
        }
        // Names in different folders are checked against their own folder: no problems.
        XCTAssertEqual(preview.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Problem")).count, 0)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor { !rename.exists })
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).sorted() == ["pack-x.zip", "song-x.mp3"] }, "\(names(in: leftTable))")
        XCTAssertTrue(app.windows.element(boundBy: 0).title.hasPrefix("Search results"))
    }
}

extension PaneUITests {
    /// "Search inside archives": names and text inside Alpha/Inner/pack.zip (docs/readme.txt, top.txt).
    func testFindFilesSearchesInsideArchives() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        let window = openFindFiles()
        window.comboBoxes["find.name"].typeText("*.txt")
        window.checkBoxes["find.archives"].click()
        window.comboBoxes["find.name"].click()
        window.comboBoxes["find.name"].typeText("\r")
        XCTAssertTrue(waitFor { self.findStatus(window).hasPrefix("Found 3 items") }, findStatus(window))
        XCTAssertTrue(findStatus(window).hasSuffix("with Live folder walk"), findStatus(window))
        let labels = window.tables["find.results"].staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains { $0.hasPrefix("readme.txt, ") && $0.contains("in Alpha/Inner/pack.zip/docs") }, "\(labels)")

        // Text inside an archived file.
        let text = window.comboBoxes["find.text"]
        text.click()
        text.typeText("readme\r")
        XCTAssertTrue(waitFor { self.findStatus(window).hasPrefix("Found 1 item") }, findStatus(window))

        window.buttons["Show in Pane"].click()
        XCTAssertTrue(waitFor { !window.exists })
        XCTAssertTrue(waitFor { self.names(in: self.leftTable) == ["readme.txt"] }, "\(names(in: leftTable))")
        XCTAssertEqual(leftTable.tableRows.firstMatch.cells.firstMatch.label, "readme.txt, in Alpha/Inner/pack.zip/docs")
        // Changing items inside archives from the results is refused with a reason.
        leftTable.typeKey(.F8, modifierFlags: [])
        XCTAssertTrue(waitFor { (self.app.staticTexts["pane.left.status"].value as? String ?? "").contains("can only be copied out") })
        // Search inside archives is remembered; turn it off again for later tests.
        let again = openFindFiles()
        XCTAssertEqual(again.checkBoxes["find.archives"].value as? Int, 1)
        again.checkBoxes["find.archives"].click()
        again.typeKey(.escape, modifierFlags: [])
    }
}
