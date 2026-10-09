import XCTest

@MainActor
final class DailyReviewUITests: XCTestCase {
    func testOptInKickstartAndWrapUpDriveDurableTaskDecisions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace"]
        app.launch()

        openDailyReviewSettings(in: app)
        let kickstartToggle = app.switches["daily-review-kickstart-enabled"]
        XCTAssertTrue(kickstartToggle.waitForExistence(timeout: 8))
        kickstartToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(
            app.switches["daily-review-kickstart-enabled"].value as? String, "1"
        )
        let wrapUpToggle = app.switches["daily-review-wrapUp-enabled"]
        XCTAssertTrue(wrapUpToggle.waitForExistence(timeout: 8))
        wrapUpToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(
            app.switches["daily-review-wrapUp-enabled"].value as? String, "1"
        )

        let settingsScreenshot = XCTAttachment(screenshot: app.screenshot())
        settingsScreenshot.name = "Opt-in morning and evening daily rhythm"
        settingsScreenshot.lifetime = .keepAlways
        add(settingsScreenshot)

        app.buttons["daily-review-start-kickstart"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["daily-review-kickstart"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["daily-review-summary-opening"].exists
        )
        app.buttons["daily-review-begin"].tap()

        let overdueID = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
        XCTAssertTrue(
            app.descendants(matching: .any)["daily-review-task-\(overdueID)"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.buttons["daily-review-done-\(overdueID)"].exists)
        XCTAssertTrue(app.buttons["daily-review-keep-\(overdueID)"].exists)
        app.buttons["daily-review-reschedule-\(overdueID)"].tap()

        let relative = app.textFields["task-reschedule-relative-due-date"]
        XCTAssertTrue(relative.waitForExistence(timeout: 8))
        relative.tap()
        relative.typeText("in 2 days")
        app.buttons["task-reschedule-relative-due-apply"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["task-reschedule-save"].tap()
        XCTAssertTrue(relative.waitForNonExistence(timeout: 8))

        let todayID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        XCTAssertTrue(
            app.descendants(matching: .any)["daily-review-task-\(todayID)"]
                .waitForExistence(timeout: 8)
        )
        let taskScreenshot = XCTAttachment(screenshot: app.screenshot())
        taskScreenshot.name = "Large swipeable Kickstart decision card"
        taskScreenshot.lifetime = .keepAlways
        add(taskScreenshot)

        app.buttons["daily-review-done-\(todayID)"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["daily-review-summary-closing"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.staticTexts["1 finished, 1 rescheduled, and 0 kept."].exists)
        app.buttons["daily-review-finish"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["daily-review-kickstart"]
                .waitForNonExistence(timeout: 8)
        )

        openDailyReviewSettings(in: app)
        XCTAssertEqual(app.switches["daily-review-kickstart-enabled"].value as? String, "1")
        XCTAssertEqual(app.switches["daily-review-wrapUp-enabled"].value as? String, "1")
        app.buttons["daily-review-start-wrapUp"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["daily-review-wrapUp"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.staticTexts["Close the loop."].exists)
        app.buttons["daily-review-begin"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["daily-review-summary-closing"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.staticTexts["Nothing is waiting for a decision. Rest easy."].exists)
        app.buttons["daily-review-finish"].tap()

        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        openDailyReviewSettings(in: app)
        XCTAssertEqual(app.switches["daily-review-kickstart-enabled"].value as? String, "1")
        XCTAssertEqual(app.switches["daily-review-wrapUp-enabled"].value as? String, "1")
    }

    func testReviewDecisionsRemainReachableAtAccessibilityTextSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        defer { app.terminate() }

        openDailyReviewSettings(in: app)
        let toggle = app.switches["daily-review-kickstart-enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let start = app.buttons["daily-review-start-kickstart"]
        scrollToAndTap(start, in: app)
        scrollToAndTap(app.buttons["daily-review-begin"], in: app)

        for taskID in ["01ARZ3NDEKTSV4RRFFQ69G5FAW", "01ARZ3NDEKTSV4RRFFQ69G5FAV"] {
            let keep = app.buttons["daily-review-keep-\(taskID)"]
            scrollToAndTap(keep, in: app)
        }
        let finish = app.buttons["daily-review-finish"]
        scrollToAndTap(finish, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["daily-review-kickstart"]
                .waitForNonExistence(timeout: 8),
            "The closing action must remain reachable, not clipped below a fixed-height card"
        )
        openDailyReviewSettings(in: app)
        XCTAssertEqual(app.switches["daily-review-kickstart-enabled"].value as? String, "1")
    }

    private func scrollToAndTap(_ button: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(button.waitForExistence(timeout: 8))
        for _ in 0..<8 {
            if button.isHittable {
                button.tap()
                return
            }
            app.swipeUp()
        }
        XCTFail("Review action must be reachable by scrolling: \(button.identifier)")
    }

    private func openDailyReviewSettings(in app: XCUIApplication) {
        let sidebar = app.buttons["project-sidebar-toggle"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        sidebar.tap()
        app.buttons["settings-open"].tap()
        let settings = app.buttons["daily-review-settings-open"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        scrollToAndTap(settings, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["daily-review-settings"]
                .waitForExistence(timeout: 8)
        )
    }
}
