import XCTest

@MainActor
final class ReminderSettingsUITests: XCTestCase {
    func testExactTimeReminderPresentsWhileAppIsForegrounded() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace"]
        app.launch()
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launch()
            self.openSettings(in: app)
            let disable = app.buttons["reminder-disable"]
            if disable.waitForExistence(timeout: 3) {
                disable.tap()
                XCTAssertTrue(disable.waitForNonExistence(timeout: 8))
            }
        }
        openSettings(in: app)
        choose("At due time", in: app)
        applyIfChanged(in: app)
        waitForUpdates(in: app)
        let enable = app.buttons["reminder-enable"]
        if enable.exists {
            enable.tap()
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
            if allow.waitForExistence(timeout: 5) {
                allow.tap()
            }
        }
        XCTAssertTrue(app.buttons["reminder-disable"].waitForExistence(timeout: 10))
        app.buttons["reminder-settings-done"].tap()
        app.buttons["task-add"].tap()
        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        let title = "Foreground timed reminder"
        name.tap()
        // Relative times round up to the next whole minute: allow up to two
        // minutes here, rather than scheduling beyond the banner wait window.
        name.typeText("\(title) in 1 minute\n")
        app.buttons["task-editor-save"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 8))
        XCTAssertEqual(app.state, .runningForeground)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notifications = springboard.staticTexts.matching(NSPredicate(format: "label == %@", title))
        let visibleBanner = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                notifications.allElementsBoundByIndex.contains(where: \.isHittable)
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [visibleBanner], timeout: 150), .completed,
                       "A real scheduled due-time notification must present over the foreground app")
        XCTAssertEqual(app.state, .runningForeground)
        let screenshot = XCTAttachment(screenshot: springboard.screenshot())
        screenshot.name = "Native due-time reminder banner over foreground OTodo"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testTimingChoicesPersistAndInvalidCustomValueKeepsSavedTiming() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace"]
        app.launch()
        openSettings(in: app)

        choose("At due time", in: app)
        applyIfChanged(in: app)
        assertSaved("At due time", in: app)
        choose("5 minutes before", in: app)
        applyIfChanged(in: app)
        assertSaved("5 minutes before", in: app)
        choose("1 hour before", in: app)
        applyIfChanged(in: app)
        assertSaved("1 hour before", in: app)

        choose("Custom hours before", in: app)
        replaceCustomValue("3", in: app)
        applyIfChanged(in: app)
        assertSaved("3 hours before", in: app)
        choose("Custom days before", in: app)
        replaceCustomValue("2", in: app)
        applyIfChanged(in: app)
        assertSaved("2 calendar days before", in: app)

        replaceCustomValue("0", in: app)
        let validation = app.staticTexts["reminder-timing-validation"]
        XCTAssertTrue(validation.waitForExistence(timeout: 5))
        let apply = app.buttons["reminder-apply-timing"]
        reveal(apply, in: app)
        XCTAssertFalse(apply.isEnabled)
        assertSaved("2 calendar days before", in: app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Invalid reminder timing preserves the saved device setting"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.terminate()
        app.launchArguments.removeAll { $0 == "-ui-testing-reset-workspace" }
        app.launch()
        openSettings(in: app)
        assertSaved("2 calendar days before", in: app)
        let custom = app.textFields["reminder-custom-value"]
        reveal(custom, in: app)
        XCTAssertEqual(custom.value as? String, "2")

        choose("At due time", in: app)
        applyIfChanged(in: app)
        assertSaved("At due time", in: app)
        app.buttons["reminder-settings-done"].tap()
        XCTAssertTrue(app.buttons["project-sidebar-toggle"].waitForExistence(timeout: 5))
    }

    private func openSettings(in app: XCUIApplication) {
        let sidebar = app.buttons["project-sidebar-toggle"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        sidebar.tap()
        let settings = app.buttons["notification-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        XCTAssertTrue(app.buttons["reminder-system-settings"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "reminder-authorization-status").firstMatch.exists)
    }

    private func choose(_ title: String, in app: XCUIApplication) {
        waitForUpdates(in: app)
        let option = app.buttons[title].firstMatch
        reveal(option, in: app)
        option.tap()
    }

    private func replaceCustomValue(_ value: String, in app: XCUIApplication) {
        waitForUpdates(in: app)
        let field = app.textFields["reminder-custom-value"]
        reveal(field, in: app)
        field.tap()
        let existing = field.value as? String ?? ""
        let digits = existing.allSatisfy(\.isNumber) ? existing.count : 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: digits) + value)
    }

    private func applyIfChanged(in app: XCUIApplication) {
        waitForUpdates(in: app)
        let apply = app.buttons["reminder-apply-timing"]
        reveal(apply, in: app)
        if apply.isEnabled { apply.tap() }
    }

    private func assertSaved(_ expected: String, in app: XCUIApplication) {
        let saved = app.descendants(matching: .any)
            .matching(identifier: "reminder-saved-timing").firstMatch
        reveal(saved, in: app)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", expected, expected),
            object: saved
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed)
    }

    private func waitForUpdates(in app: XCUIApplication) {
        let progress = app.descendants(matching: .any)
            .matching(identifier: "reminder-updating").firstMatch
        XCTAssertTrue(progress.waitForNonExistence(timeout: 8))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 5 where !element.isHittable {
            app.swipeUp()
        }
        if !element.isHittable {
            for _ in 0 ..< 7 where !element.isHittable {
                app.swipeDown()
            }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
    }
}
