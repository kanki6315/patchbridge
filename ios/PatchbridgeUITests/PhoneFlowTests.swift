import XCTest

final class PhoneFlowTests: XCTestCase {
    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 1) // Let sheet/theme/rotation transitions finish before capturing.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    /// The iPhone Duo screen the app is on, from the window size: no other iPhone is wider than 440 pt.
    private func duoScreen(_ app: XCUIApplication) -> String? {
        let size = app.windows.firstMatch.frame.size
        let short = min(size.width, size.height)
        guard UIDevice.current.userInterfaceIdiom == .phone, short >= 450 else { return nil }
        return short >= 600 ? "inner" : "outer"
    }
    func testDemoEditingSavingAndAppearance() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone navigation only; see testPadWorkspace") }
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--stage"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Dirty Riffage"].waitForExistence(timeout: 10))
        if duoScreen(app) != nil { throw XCTSkip("iPhone Duo layouts; see testDuoWorkspace") }
        capture("Stage overview")
        // Transpose's SEMITONES control has the unit "Semitones"; its row summary says it once.
        let transpose = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Semitones -1")).firstMatch
        XCTAssertTrue(transpose.exists)
        XCTAssertFalse(transpose.label.contains("-1 Semitones"))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Opto Comp")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Increase THRESHOLD"].waitForExistence(timeout: 5))
        capture("Stage editor")
        app.buttons["Increase THRESHOLD"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Enter exact value")).firstMatch.exists)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Enter exact value")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Clear"].waitForExistence(timeout: 5))
        app.buttons["Clear"].tap(); app.buttons["9"].tap(); app.buttons["9"].tap()
        XCTAssertFalse(app.buttons["Set"].isEnabled)
        capture("Invalid exact entry")
        app.buttons["Clear"].tap(); app.buttons["2"].tap(); app.buttons["0"].tap(); app.buttons["Change sign"].tap()
        XCTAssertTrue(app.buttons["Set"].isEnabled)
        app.buttons["Set"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "-20.0")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Save"].tap()
        app.buttons["Save demo preset"].tap()
        XCTAssertTrue(app.staticTexts["Saved in demo only"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Demo preset"].tap()
        XCTAssertTrue(app.buttons["Connect my QC"].waitForExistence(timeout: 5))
        capture("Demo exit")
        app.buttons["Appearance"].tap()
        let midnight = app.buttons["theme-Midnight"]
        XCTAssertTrue(midnight.waitForExistence(timeout: 5))
        midnight.tap()
        expectation(for: NSPredicate(format: "value == 'Selected'"), evaluatedWith: midnight)
        waitForExpectations(timeout: 5)
        capture("Midnight appearance")
        app.buttons["Light"].tap()
        XCTAssertTrue(midnight.waitForExistence(timeout: 5))
        XCTAssertEqual(midnight.value as? String, "Selected")
        capture("Midnight light appearance")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Demo preset"].waitForExistence(timeout: 5))
        capture("Midnight light overview")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Edit block"].waitForExistence(timeout: 5))
        capture("iPhone landscape")
        XCUIDevice.shared.orientation = .portrait
    }
    /// Taps the switch itself; a tap on its label doesn't always flip it.
    private func flip(_ toggle: XCUIElement) {
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }
    func testLiveTunerStaysOnEveryScreen() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone tuner line only") }
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--stage"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Dirty Riffage"].waitForExistence(timeout: 10))
        if duoScreen(app) != nil { throw XCTSkip("iPhone Duo layouts; see testDuoWorkspace") }
        XCTAssertFalse(app.buttons["tuner-line"].exists)
        app.buttons["tuner-button"].tap()
        XCTAssertTrue(app.switches["Mute output"].waitForExistence(timeout: 5))
        capture("Full tuner")
        flip(app.switches["Live tuner"])
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["tuner-line"].waitForExistence(timeout: 5))
        capture("Live tuner line")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Opto Comp")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Increase THRESHOLD"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tuner-line"].waitForExistence(timeout: 2), "The line stays in the block editor")
        capture("Live tuner in the editor")
        app.buttons["tuner-line"].tap()
        XCTAssertTrue(app.switches["Live tuner"].waitForExistence(timeout: 5))
        flip(app.switches["Live tuner"])
        app.buttons["Done"].tap()
        XCTAssertFalse(app.buttons["tuner-line"].waitForExistence(timeout: 2))
    }
    func testWelcomeAndReadOnlyBlock() {
        let app = XCUIApplication()
        app.launchArguments = ["--stage"]
        app.launch()
        XCTAssertTrue(app.buttons["Find my Mac"].waitForExistence(timeout: 10))
        capture("Welcome")
        app.buttons["Not installed? Get the Mac app"].tap()
        XCTAssertTrue(app.buttons["Send to my Mac"].waitForExistence(timeout: 5))
        capture("Get Mac app")
        app.buttons["Done"].tap()
        app.buttons["Try the demo preset"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Bad Horse")).firstMatch.tap()
        XCTAssertFalse(app.buttons["Increase POSITION"].exists)
        capture("Read-only block")
    }
    func testPadWorkspace() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout only") }
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--stage"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        // The editor panel is on screen without navigating; Opto Comp is selected by default.
        XCTAssertTrue(app.buttons["Increase THRESHOLD"].waitForExistence(timeout: 10))
        capture("iPad landscape")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Enter exact value")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Set"].waitForExistence(timeout: 5))
        app.buttons["Clear"].tap(); app.buttons["3"].tap(); app.buttons["0"].tap(); app.buttons["Change sign"].tap()
        capture("iPad typing popover")
        app.buttons["Set"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "-30.0")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Save demo preset"].tap()
        XCTAssertTrue(app.staticTexts["Save this demo preset?"].waitForExistence(timeout: 5))
        capture("iPad save popover")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Saved in demo only"].waitForExistence(timeout: 5))
        app.buttons["Demo preset"].tap()
        XCTAssertTrue(app.buttons["Connect my QC"].waitForExistence(timeout: 5))
        capture("iPad demo popover")
        app.buttons["Appearance"].tap()
        XCTAssertTrue(app.buttons["theme-Midnight"].waitForExistence(timeout: 5))
        capture("iPad appearance")
        // Retarget the panel from the grid.
        app.tap()
        app.buttons["Dual Chorus"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Row 3"].waitForExistence(timeout: 5))
        capture("iPad option parameter")
        XCUIDevice.shared.orientation = .portrait
        capture("iPad portrait")
    }
    /// Scene buttons on iPhone and iPad. The demo confirms at once; Save is never touched.
    func testSceneSwitchingInTheDemo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--stage"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Dirty Riffage"].waitForExistence(timeout: 10))
        if duoScreen(app) != nil { throw XCTSkip("The Duo's scene pads are covered by testDuoWorkspace") }
        XCTAssertTrue(app.buttons["Scene F · RHYTHM, active"].exists)
        let unsaved = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Unsaved")).count
        app.buttons["Scene B · CRONCH"].tap()
        XCTAssertTrue(app.buttons["Scene B · CRONCH, active"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Scene F · RHYTHM, active"].exists)
        capture("Scene switched")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Unsaved")).count, unsaved,
                       "A scene switch never changes the unsaved state")
        // A scene without a QC name goes by its letter alone.
        app.buttons["Scene C"].tap()
        XCTAssertTrue(app.buttons["Scene C, active"].waitForExistence(timeout: 5))
    }

    func testFailedSceneSwitchIsShownInTheBlockEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--stage", "--editor", "--block=2:6", "--refuse-scene=D", "--unknown-scene=E"]
        app.launch()
        if duoScreen(app) != nil || UIDevice.current.userInterfaceIdiom != .phone { throw XCTSkip("The iPhone block editor's scene pill") }
        let pill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Scene F")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Scene D")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Scene D not applied · the QC stayed on F"].waitForExistence(timeout: 5)
                      || app.descendants(matching: .any)["Scene D not applied. The QC stayed on Scene F · RHYTHM."].exists)
        XCTAssertTrue(app.staticTexts["Edits scene F only"].exists, "The dial keeps editing the QC's scene")
        capture("Scene not applied in the editor")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Scene D not applied")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Scene E")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Switch to scene E: outcome unknown · showing F"].waitForExistence(timeout: 5))
        capture("Scene outcome unknown in the editor")
    }

    func testDuoWorkspace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--stage"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Dirty Riffage"].waitForExistence(timeout: 10))
        guard let screen = duoScreen(app) else { throw XCTSkip("iPhone Duo layouts only") }
        let optoComp = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Opto Comp")).firstMatch
        if screen == "inner" {
            // The deck under the hinge holds the scene pads, then edits in place without navigating.
            XCTAssertTrue(app.staticTexts["Scenes"].exists)
            app.buttons["Scene B · CRONCH"].tap()
            XCTAssertTrue(app.buttons["Scene B · CRONCH, active"].waitForExistence(timeout: 5))
            capture("Duo unfolded scenes")
            optoComp.tap()
            XCTAssertTrue(app.buttons["Increase THRESHOLD"].waitForExistence(timeout: 5))
            capture("Duo unfolded editing")
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Enter exact value")).firstMatch.tap()
            XCTAssertTrue(app.buttons["Set"].waitForExistence(timeout: 5))
            app.buttons["Clear"].tap(); app.buttons["3"].tap(); app.buttons["0"].tap(); app.buttons["Change sign"].tap()
            capture("Duo typing beside the dial")
            app.buttons["Set"].tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "-30.0")).firstMatch.waitForExistence(timeout: 5))
            app.buttons["Save"].tap()
            app.buttons["Save demo preset"].tap()
            XCTAssertTrue(app.staticTexts["Saved in demo only"].waitForExistence(timeout: 5))
            app.buttons["Scenes"].tap()
            XCTAssertTrue(app.staticTexts["Scenes"].waitForExistence(timeout: 5))
            // A block's editor survives the sideways fallback layout.
            app.buttons["Dual Chorus"].firstMatch.tap()
            XCTAssertTrue(app.buttons["Scenes"].waitForExistence(timeout: 5))
            XCUIDevice.shared.orientation = .landscapeLeft
            capture("Duo sideways fallback")
            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(app.buttons["Scenes"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Increase MIX"].exists)
            capture("Duo editor after rotation")
        } else {
            capture("Duo folded portrait")
            optoComp.tap()
            XCTAssertTrue(app.buttons["Increase THRESHOLD"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Open editor"].exists)
            capture("Duo block menu sheet")
            app.buttons["Increase THRESHOLD"].tap()
            app.buttons["Close"].tap()
            app.buttons["Save demo preset"].tap()
            XCTAssertTrue(app.staticTexts["Save this demo preset?"].waitForExistence(timeout: 5))
            // iOS 26 anchors the confirmation to the Save button as a popover; both are labelled "Save demo preset".
            let confirm = app.popovers.buttons["Save demo preset"]
            (confirm.exists ? confirm : app.sheets.buttons["Save demo preset"]).tap()
            XCTAssertTrue(app.staticTexts["Saved in demo only"].waitForExistence(timeout: 5))
            optoComp.tap()
            XCTAssertTrue(app.staticTexts["Saved in demo only"].isHittable,
                          "Edit outcomes must remain visible above the portrait menu")
            capture("Duo portrait menu notice")
            XCUIDevice.shared.orientation = .landscapeLeft
            // The menu stays open as a side panel beside the grid.
            XCTAssertTrue(app.buttons["Increase THRESHOLD"].waitForExistence(timeout: 5))
            capture("Duo block menu panel")
            app.buttons["Open editor"].tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Enter exact value")).firstMatch.waitForExistence(timeout: 5))
            capture("Duo folded editor")
            XCUIDevice.shared.orientation = .portrait
        }
    }
}
