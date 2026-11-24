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
        XCTAssertTrue(waitFor { self.findStatus(window).hasPrefix("Found 1 item") }, findStatus(window))
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
