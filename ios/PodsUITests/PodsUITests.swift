import XCTest

/// Drives the real app against the live Mac library. The app runs read-only
/// (`-PodsReadOnly YES`), so nothing here changes the shared library.
final class PodsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-PodsReadOnly", "YES"]
        app.launch()
        pairIfNeeded()
    }

    private func pairIfNeeded() {
        let field = app.textFields["Pairing code"]
        guard field.waitForExistence(timeout: 3) else { return }
        guard let code = ProcessInfo.processInfo.environment["PODS_PAIR_CODE"], !code.isEmpty else {
            XCTFail("The app is not paired. Run with TEST_RUNNER_PODS_PAIR_CODE=$(python3 mac/backend/manage.py pair)."); return
        }
        field.tap()
        field.typeText(code)
        app.buttons["Pair"].tap()
        XCTAssertTrue(app.navigationBars["Listen"].waitForExistence(timeout: 30))
    }

    private func seconds(_ clock: String) -> Double {
        clock.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    private var position: Double { seconds(app.sliders["Position"].value as? String ?? "0:00") }

    /// The first Listen episode that is already on the device.
    private func firstDownloadedRow() -> XCUIElement? {
        let rows = app.buttons.matching(identifier: "listen-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "Listen shows episodes")
        for index in 0..<min(rows.count, 8) where rows.element(boundBy: index).images["Downloaded"].exists {
            return rows.element(boundBy: index)
        }
        return nil
    }

    func testPlaybackControls() throws {
        guard let row = firstDownloadedRow() else { throw XCTSkip("No downloaded episode yet") }
        row.tap()
        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "tapping a downloaded episode starts playback")
        let start = position
        sleep(4)
        XCTAssertGreaterThan(position, start + 1, "the playhead advances")

        let beforeSkip = position
        app.buttons["Forward 30 seconds"].tap()
        XCTAssertGreaterThanOrEqual(position, beforeSkip + 25)
        app.buttons["Back 15 seconds"].tap()
        XCTAssertLessThan(position, beforeSkip + 25)

        let speeds = ["1×", "1.5×", "2×", "2.5×", "3×"].map { app.buttons[$0] }
        XCTAssertTrue(speeds.allSatisfy { $0.exists })
        let original = try XCTUnwrap(speeds.first { $0.isSelected })
        let target = try XCTUnwrap(speeds.first { !$0.isSelected })
        target.tap()
        XCTAssertTrue(target.isSelected)
        XCTAssertFalse(original.isSelected)
        original.tap()
        XCTAssertTrue(original.isSelected)

        pause.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5))
        let paused = position
        sleep(2)
        XCTAssertEqual(position, paused, accuracy: 0.5, "paused playback stays put")

        app.buttons["Close player"].tap()
        let mini = app.otherElements["mini-player"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5), "the mini player remains after closing the sheet")
        mini.tap()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 5), "tapping the mini player reopens it")
    }

    func testMarkPlayedMovesEpisodeToPlayed() throws {
        guard let row = firstDownloadedRow() else { throw XCTSkip("No downloaded episode yet") }
        let rows = app.buttons.matching(identifier: "listen-row")
        row.tap()
        XCTAssertTrue(app.buttons["Mark played"].waitForExistence(timeout: 10))
        let title = app.staticTexts["player-title"].label
        app.buttons["Mark played"].tap()
        XCTAssertTrue(app.navigationBars["Listen"].waitForExistence(timeout: 5))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.matching(NSPredicate(format: "label CONTAINS %@", title)).count, 0, "the episode leaves Listen")
        app.tabBars.buttons["Played"].tap()
        let first = app.descendants(matching: .any).matching(identifier: "played-row").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(first.label.contains(title), "it is first in Played: \(first.label) vs \(title)")
    }

    func testShowsSettingsAndAdd() {
        app.tabBars.buttons["Shows"].tap()
        let show = app.cells.firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 10))
        show.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "show-episode-row").firstMatch.waitForExistence(timeout: 5), "a show lists its episodes")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.navigationBars["Shows"].buttons["Add"].tap()
        let add = app.navigationBars["Add"].buttons["Add"]
        XCTAssertFalse(add.isEnabled)
        let field = app.textFields.firstMatch
        field.tap()
        field.typeText("not a url")
        XCTAssertFalse(add.isEnabled, "only http(s) addresses are accepted")
        field.typeText(XCUIKeyboardKey.delete.rawValue.repeated(9))
        field.typeText("https://example.com/feed.xml")
        XCTAssertTrue(add.isEnabled)
        app.buttons["Cancel"].tap()

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Last sync"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Play the next episode automatically"].exists)
        XCTAssertTrue(app.staticTexts["Used"].exists)
        XCTAssertFalse(app.staticTexts["Never"].exists, "the app has synced with the Mac")
    }
}

private extension String {
    func repeated(_ count: Int) -> String { String(repeating: self, count: count) }
}
