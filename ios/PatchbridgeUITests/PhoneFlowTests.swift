import XCTest

final class PhoneFlowTests: XCTestCase {
    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 1) // Let sheet/theme/rotation transitions finish before capturing.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testDemoEditingSavingAndAppearance() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--stage"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Tremonti w Mic"].waitForExistence(timeout: 10))
        capture("Stage overview")
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
        app.buttons["Appearance"].tap()
        let daylight = app.buttons["theme-Daylight"]
        XCTAssertTrue(daylight.waitForExistence(timeout: 5))
        daylight.tap()
        XCTAssertTrue(daylight.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == 'Selected'"), evaluatedWith: daylight)
        waitForExpectations(timeout: 5)
        capture("Daylight appearance")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Demo preset"].waitForExistence(timeout: 5))
        capture("Daylight overview")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Edit block"].waitForExistence(timeout: 5))
        capture("iPhone landscape")
        XCUIDevice.shared.orientation = .portrait
    }
    func testWelcomeAndReadOnlyBlock() {
        let app = XCUIApplication()
        app.launchArguments = ["--stage"]
        app.launch()
        XCTAssertTrue(app.buttons["Find my Mac"].waitForExistence(timeout: 10))
        capture("Welcome")
        app.buttons["Get Patchbridge for Mac"].tap()
        XCTAssertTrue(app.buttons["Send to my Mac"].waitForExistence(timeout: 5))
        capture("Get Mac app")
        app.buttons["Done"].tap()
        app.buttons["Try the demo preset"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Bad Horse")).firstMatch.tap()
        XCTAssertFalse(app.buttons["Increase POSITION"].exists)
        capture("Read-only block")
    }
}
