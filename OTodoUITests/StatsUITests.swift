import XCTest

@MainActor
final class StatsUITests: XCTestCase {
    func testOfflineWeeklyActivitySurvivesRelaunchInLightAndDark() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-light"]
        app.launch()
        defer { app.terminate() }
        openStats(in: app)
        assertMetric("stats-finished", value: "0", in: app)
        assertMetric("stats-created", value: "0", in: app)
        app.buttons["stats-close"].tap()

        app.buttons["task-add"].tap()
        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText("Weekly evidence")
        app.buttons["task-editor-save"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 8))
        let complete = app.buttons["Complete Weekly evidence"]
        XCTAssertTrue(complete.waitForExistence(timeout: 8))
        complete.tap()
        XCTAssertTrue(complete.waitForNonExistence(timeout: 8))

        openStats(in: app)
        assertMetric("stats-finished", value: "1", in: app)
        assertMetric("stats-created", value: "1", in: app)
        assertMetric("stats-on-time", value: "1 of 1", in: app)
        attach("Weekly Stats · light · offline completion", app: app)
        app.buttons["stats-previous-week"].tap()
        assertMetric("stats-finished", value: "0", in: app)
        app.buttons["stats-current-week"].tap()
        assertMetric("stats-finished", value: "1", in: app)

        app.terminate()
        app.launchArguments = ["-ui-testing", "-ui-testing-dark"]
        app.launch()
        openStats(in: app)
        assertMetric("stats-finished", value: "1", in: app)
        assertMetric("stats-created", value: "1", in: app)
        assertMetric("stats-on-time", value: "1 of 1", in: app)
        attach("Weekly Stats · dark · durable relaunch", app: app)
        let list = app.descendants(matching: .any).matching(identifier: "stats-list").firstMatch
        let coverage = app.descendants(matching: .any).matching(identifier: "stats-coverage").firstMatch
        for _ in 0..<8 where !coverage.isHittable { list.swipeUp() }
        XCTAssertTrue(coverage.exists)
        attach("Weekly Stats · history coverage and advanced features", app: app)
    }

    func testWarmReminderWaitsForStatsDismissal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-notification-task",
            "01ARZ3NDEKTSV4RRFFQ69G5FAX", "-ui-testing-notification-on-activation",
        ]
        app.launch()
        defer { app.terminate() }
        openStats(in: app)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8))
        app.activate()
        XCTAssertTrue(app.buttons["stats-close"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.textFields["task-editor-name"].exists)
        app.buttons["stats-close"].tap()
        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Future todo"), object: name)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed)
    }

    private func openStats(in app: XCUIApplication) {
        let sidebar = app.buttons["project-sidebar-toggle"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 8))
        sidebar.tap()
        let stats = app.buttons["stats-open"]
        XCTAssertTrue(stats.waitForExistence(timeout: 8))
        stats.tap()
        XCTAssertTrue(app.buttons["stats-close"].waitForExistence(timeout: 8))
    }

    private func assertMetric(_ identifier: String, value: String, in app: XCUIApplication) {
        let metric = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(metric.waitForExistence(timeout: 8))
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: metric)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed)
    }

    private func attach(_ title: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = title
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
