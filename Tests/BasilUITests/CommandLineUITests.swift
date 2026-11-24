import XCTest

/// The pane's command line (Left or Right) and its output window.
extension PaneUITests {
    var commandField: XCUIElement { app.textFields["commandLine.field"] }

    func openCommandLine(with key: XCUIKeyboardKey = .rightArrow, line: UInt = #line) {
        leftTable.typeKey(key, modifierFlags: [])
        XCTAssertTrue(commandField.waitForExistence(timeout: 2), line: line)
        XCTAssertTrue(waitFor { (self.commandField.value(forKey: "hasKeyboardFocus") as? Bool) == true }, line: line)
    }

    func testCommandLineRunsCommandsAndChangesFolders() throws {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        openCommandLine()
        XCTAssertEqual(commandField.label, "Command in \(app.windows.element(boundBy: 0).title.replacingOccurrences(of: " - Basil", with: ""))")
        commandField.typeText("echo hello-basil\r")

        let output = app.windows["echo hello-basil"]
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        XCTAssertTrue(output.textViews.matching(NSPredicate(format: "value CONTAINS %@", "hello-basil")).firstMatch.waitForExistence(timeout: 5))
        let status = output.staticTexts["commandOutput.status"]
        XCTAssertTrue(waitFor { (status.value as? String) == "Finished, 1 line" }, "\(status.value ?? "")")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        try audit(app) { issue in
            if self.isCoveredElsewhere(issue, by: output) { return true }
            print("AUDIT command output: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        output.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitFor { !output.exists })

        // cd changes the pane's folder; a quick silent command opens no window.
        openCommandLine(with: .leftArrow)
        commandField.typeText("cd Beta\r")
        XCTAssertTrue(waitFor { self.app.windows.element(boundBy: 0).title.hasPrefix("Beta") }, app.windows.element(boundBy: 0).title)
        XCTAssertFalse(commandField.exists)
        openCommandLine()
        commandField.typeText("touch made.txt\r")
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).contains("made.txt") }, "\(names(in: leftTable))")
        XCTAssertEqual(app.windows.count, 1)

        // Up and Down go through earlier commands; Escape goes back to the list.
        openCommandLine()
        commandField.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(waitFor { (self.commandField.value as? String) == "touch made.txt" })
        commandField.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(waitFor { (self.commandField.value as? String) == "cd Beta" })
        commandField.typeKey(.downArrow, modifierFlags: [])
        commandField.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitFor { (self.commandField.value as? String ?? "").isEmpty || self.commandField.placeholderValue == self.commandField.value as? String })
        commandField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitFor { !self.commandField.exists })
    }

    func testCommandLineStopsALongCommand() {
        XCTAssertTrue(waitFor { self.names(in: self.leftTable).count == 6 })
        openCommandLine()
        commandField.typeText("sleep 30\r")
        let output = app.windows["sleep 30"]
        XCTAssertTrue(output.waitForExistence(timeout: 4))
        let status = output.staticTexts["commandOutput.status"]
        XCTAssertTrue((status.value as? String)?.hasPrefix("Running in") == true, "\(status.value ?? "")")
        output.buttons["Stop Command"].click()
        XCTAssertTrue(waitFor({ (status.value as? String) == "Stopped" }, timeout: 5), "\(status.value ?? "")")
        output.buttons["Close"].click()
        XCTAssertTrue(waitFor { !output.exists })
    }
}
