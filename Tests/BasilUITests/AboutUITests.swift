import XCTest

/// Basil > About Basil: the window, its License and Acknowledgements sheets, keyboard closing,
/// and the accessibility audit.
@MainActor
final class AboutUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["BASIL_UITEST_FIXTURE"] = "1"
        app.launch()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    var about: XCUIElement { app.windows["About Basil"] }

    func openAbout() {
        XCTAssertTrue(app.tables["pane.left.table"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Basil"].click()
        app.menuItems["About Basil"].click()
        XCTAssertTrue(about.waitForExistence(timeout: 3))
    }

    /// The sheet's read-only text view holds `text`.
    func waitForValue(in sheet: XCUIElement, containing text: String) -> Bool {
        sheet.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 3)
    }

    func auditAbout(_ window: XCUIElement) throws {
        // The audit samples screen pixels: let the window's (or sheet's) fade-in finish first,
        // or whatever text it samples mid-animation fails "Contrast".
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        try audit(app) { issue in
            if self.isCoveredElsewhere(issue, by: window) { return true }
            print("AUDIT about: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
    }

    func testAboutShowsVersionDeveloperAndLinks() throws {
        openAbout()
        XCTAssertTrue(about.staticTexts["Basil"].exists)
        XCTAssertTrue(about.staticTexts["Developed by Flameborn"].exists)
        XCTAssertTrue(about.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Version '")).firstMatch.exists)
        for name in ["GitHub Page", "License", "Acknowledgements", "Check for Updates...", "Close"] {
            XCTAssertTrue(about.buttons[name].exists, name)
        }
        XCTAssertTrue(about.images["Basil app icon"].exists)
        try auditAbout(about)

        about.buttons["License"].click()
        let sheet = about.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue(in: sheet, containing: "Permission is hereby granted"))
        try auditAbout(sheet)
        sheet.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))

        about.buttons["Acknowledgements"].click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue(in: sheet, containing: "libarchive: BSD 2-Clause License"))
        sheet.buttons["Done"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))

        about.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(about.waitForNonExistence(timeout: 3))
        openAbout()
        about.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(about.waitForNonExistence(timeout: 3))
    }
}

/// Basil > Check for Updates... with a made-up release (BASIL_UITEST_UPDATE=1): the offer sheet
/// shows the version and the release notes, passes the audit, and Remind Me Later closes it.
/// Without a release, the check says Basil is up to date.
@MainActor
final class UpdateUITests: XCTestCase {
    var app: XCUIApplication!

    override func tearDown() async throws {
        app?.terminate()
    }

    func launch(offer: Bool) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["BASIL_UITEST_FIXTURE"] = "1"
        if offer { app.launchEnvironment["BASIL_UITEST_UPDATE"] = "1" }
        app.launch()
        XCTAssertTrue(app.tables["pane.left.table"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Basil"].click()
        app.menuItems["Check for Updates..."].click()
    }

    func testUpdateOfferShowsReleaseNotes() throws {
        launch(offer: true)
        let sheet = app.windows.firstMatch.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["Basil 99.0.0 is available"].exists, sheet.debugDescription)
        let notes = sheet.textViews["What's new"]
        XCTAssertTrue(notes.exists, sheet.debugDescription)
        XCTAssertEqual(notes.value as? String, "Added\nUpdates from GitHub releases\nA new About window")
        for name in ["Install and Relaunch", "Skip This Version", "Remind Me Later"] {
            XCTAssertTrue(sheet.buttons[name].exists, name)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        try audit(app) { issue in
            if self.isCoveredElsewhere(issue, by: sheet) { return true }
            // The system NSAlert draws its texts on translucent glass over the panes, and the audit
            // reports them although they measure well above the limit (like the delete dialog's text in
            // PaneUITests.testFileOperationsWithKeyboard).
            if issue.auditType == .contrast, let value = issue.element?.value as? String,
               value == "Basil 99.0.0 is available" || value.hasPrefix("You have Basil ") { return true }
            print("AUDIT update: \(issue.auditType) \(issue.compactDescription) element=\(issue.element?.debugDescription.prefix(300) ?? "nil")")
            return false
        }
        sheet.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))
    }

    func testUpToDate() throws {
        launch(offer: false)
        let sheet = app.windows.firstMatch.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["Basil is up to date."].exists, sheet.debugDescription)
        sheet.buttons["OK"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))
    }
}
