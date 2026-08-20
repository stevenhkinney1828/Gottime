import XCTest

/// Walks the canonical flow from spec section 1: choose person -> duration -> explicit
/// confirm -> simulated ringing -> simulated answer -> countdown -> automatic ending ->
/// history entry. Runs entirely against GotTimeMocks (no live credentials) — this is what
/// ios-ci.yml actually executes on every push.
final class GotTimeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(timeScale: String = "60") -> XCUIApplication {
        let app = XCUIApplication()
        // Far more aggressive than the 10x a human testing the app manually would want (see
        // AppEnvironment.mock()) — this test has nothing to watch, only to verify, so a
        // 5-minute call finishing in ~5 real seconds keeps the whole suite fast.
        app.launchEnvironment["GOTTIME_DEV_TIME_SCALE"] = timeScale
        app.launch()
        return app
    }

    func testAppLaunchesToThePeopleList() throws {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["GotTime?"].waitForExistence(timeout: 5))
    }

    func testCanonicalFlow_pickPersonDurationRingConnectCountdownEndHistory() throws {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["GotTime?"].waitForExistence(timeout: 5))

        // 1. Choose person. MockData seeds two connections (Chris, Jordan), so the People
        // screen shows a list rather than the single-person fast path.
        let chrisRow = app.buttons["Call Chris"]
        XCTAssertTrue(chrisRow.waitForExistence(timeout: 5))
        chrisRow.tap()

        // 2. Choose duration — 5 minutes, which at the 60x test time scale runs in ~5s.
        let fiveMinuteChip = app.buttons["5 min"]
        XCTAssertTrue(fiveMinuteChip.waitForExistence(timeout: 5))
        fiveMinuteChip.tap()

        // Selecting a duration alone must not start the call (spec section 6) — the
        // explicit-confirm button is what actually calls, and only appears with the full
        // "Call Chris for 5 minutes" phrasing once a duration is chosen.
        let confirmButton = app.buttons["Call Chris for 5 minutes"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 3))

        // 3. Explicit confirm.
        confirmButton.tap()

        // 4. Simulated ringing, then 5. simulated answer (MockVoiceService auto-connects by
        // default) -> 6. countdown becomes visible.
        let timeRemainingLabel = app.staticTexts["Time remaining"]
        XCTAssertTrue(timeRemainingLabel.waitForExistence(timeout: 8), "call should reach connected within the ringing window")

        // 7. Automatic ending — at 60x scale, 5 minutes (300s) takes ~5s, plus teardown.
        let timesUpTitle = app.staticTexts["Time's up"]
        XCTAssertTrue(timesUpTitle.waitForExistence(timeout: 15), "call must auto-terminate at zero without any confirmation")

        // No "extend" affordance exists anywhere on the post-call screen (spec section 2).
        XCTAssertFalse(app.buttons["Extend"].exists)

        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.exists)
        doneButton.tap()

        // 8. History entry. Seed data (MockData.defaultHistory) already includes Chris rows,
        // so checking for "Chris" text existing wouldn't actually prove *this* call was
        // recorded — it would trivially pass even if recording were broken. Counting rows
        // before/after is the real proof: seed data is exactly 6 entries, so a freshly
        // completed 7th is unambiguous.
        XCTAssertTrue(app.navigationBars["GotTime?"].waitForExistence(timeout: 5))
        let historyButton = app.buttons["Call history"]
        XCTAssertTrue(historyButton.waitForExistence(timeout: 5))
        historyButton.tap()

        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Chris"].waitForExistence(timeout: 5))

        // Scoped to History's own list via its accessibilityIdentifier, not a bare `app.cells`
        // — that query walks the *entire* app hierarchy, not just the visible screen, and
        // silently included PeopleListView's own 2 rows (Chris, Jordan) even while covered by
        // this sheet: exactly 2 extra (9 instead of 7) is what actually surfaced once the
        // active-call-presentation bug blocking the whole flow was fixed and the test could
        // reach this assertion for the first time. `.cells` (not `.tables.cells`) on the scoped
        // element so this still doesn't depend on whether SwiftUI's List happens to back onto a
        // table view or a collection view for the Xcode/iOS version this runs against.
        let historyList = app.descendants(matching: .any).matching(identifier: "historyList").firstMatch
        let historyRowCount = historyList.cells.count
        XCTAssertEqual(
            historyRowCount, 7,
            "expected the 6 seeded history entries plus the one just completed in this test"
        )
    }
}
