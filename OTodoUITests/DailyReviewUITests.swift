import XCTest

@MainActor
final class DailyReviewUITests: XCTestCase {
    func testReviewAffirmationCompletionAndReschedulingSurviveRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-light"]
        app.launch()
        defer { app.terminate() }
        openSettings(in: app)
        let morning = app.switches["daily-review-enabled-morning"]
        let evening = app.switches["daily-review-enabled-evening"]
        XCTAssertEqual(morning.value as? String, "0", "Reviews require explicit opt-in")
        XCTAssertEqual(evening.value as? String, "0")
        morning.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(morning.value as? String, "1", "Explicit opt-in must take effect before starting a review")
        tap("daily-review-open-morning", in: app)
        capture("Kickstart opening summary", in: app)
        tap("daily-review-next", in: app)
        assertVisibleTitle("Overdue todo", in: app)
        tap("daily-review-lfg", in: app)
        assertVisibleTitle("Seed todo", in: app)
        tap("daily-review-back", in: app)
        assertVisibleTitle("Overdue todo", in: app)
        XCTAssertTrue(visibleButton("daily-review-complete", in: app).isEnabled,
                      "LFG must leave the todo actionable")
        tap("daily-review-complete", in: app)
        assertVisibleTitle("Seed todo", in: app)
        tap("daily-review-reschedule", in: app)
        let relative = app.textFields["task-reschedule-relative-due-date"]
        XCTAssertTrue(relative.waitForExistence(timeout: 8))
        relative.tap()
        relative.typeText("in 1 day")
        app.buttons["task-reschedule-relative-due-apply"].tap()
        app.buttons["task-reschedule-save"].tap()
        XCTAssertTrue(relative.waitForNonExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["daily-review-error"].exists)
        tap("daily-review-back", in: app)
        assertVisibleTitle("Seed todo", in: app)
        capture("Kickstart saved schedule", in: app)
        app.navigationBars.buttons["Close"].firstMatch.tap()
        app.terminate()
        app.launchArguments.removeAll { $0 == "-ui-testing-reset-workspace" }
        app.launch()
        openSettings(in: app)
        XCTAssertEqual(app.switches["daily-review-enabled-morning"].value as? String, "1")
        XCTAssertEqual(app.switches["daily-review-enabled-evening"].value as? String, "0",
                       "The two reviews opt in independently")
        tap("daily-review-open-morning", in: app)
        assertVisibleTitle("Seed todo", in: app)
        tap("daily-review-next", in: app)
        tap("daily-review-next", in: app)
        capture("Kickstart closing summary", in: app)
        tap("daily-review-finish", in: app)
        tap("daily-review-open-evening", in: app)
        capture("Wrap up opening summary", in: app)
        tap("daily-review-next", in: app)
        tap("daily-review-next", in: app)
        capture("Wrap up closing summary", in: app)
        tap("daily-review-finish", in: app)
        app.navigationBars.buttons["Done"].firstMatch.tap()

        app.buttons["task-search-open"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("Overdue todo")
        let completed = app.buttons["task-row-01ARZ3NDEKTSV4RRFFQ69G5FAW"]
        XCTAssertTrue(completed.waitForExistence(timeout: 8))
        XCTAssertTrue(completed.label.contains("State: Done"))
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Overdue todo".count) + "Seed todo")
        let rescheduled = app.buttons["task-row-01ARZ3NDEKTSV4RRFFQ69G5FAV"]
        XCTAssertTrue(rescheduled.waitForExistence(timeout: 8))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertTrue(rescheduled.label.contains("Due: \(formatter.string(from: tomorrow))"))
        XCTAssertTrue(rescheduled.label.contains("State: Pending"), "Rescheduling must not complete the todo")
    }

    private func openSettings(in app: XCUIApplication) {
        let sidebar = app.buttons["project-sidebar-toggle"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        sidebar.tap()
        tap("daily-review-settings-open", in: app)
        XCTAssertTrue(app.switches["daily-review-enabled-morning"].waitForExistence(timeout: 8))
    }

    private func visibleButton(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let buttons = app.buttons.matching(identifier: identifier)
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            buttons.allElementsBoundByIndex.contains(where: \.isHittable)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 8), .completed)
        return buttons.allElementsBoundByIndex.first(where: \.isHittable) ?? buttons.firstMatch
    }

    private func tap(_ identifier: String, in app: XCUIApplication) {
        let buttons = app.buttons.matching(identifier: identifier)
        XCTAssertTrue(buttons.firstMatch.waitForExistence(timeout: 8))
        for _ in 0..<4 where !buttons.allElementsBoundByIndex.contains(where: \.isHittable) {
            app.swipeUp()
        }
        visibleButton(identifier, in: app).tap()
    }

    private func assertVisibleTitle(_ title: String, in app: XCUIApplication) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.staticTexts.matching(NSPredicate(format: "label == %@", title))
                .allElementsBoundByIndex.contains(where: \.isHittable)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 8), .completed)
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
