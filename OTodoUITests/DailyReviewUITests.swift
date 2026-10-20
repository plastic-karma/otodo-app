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
        settingsScreenshot.name = "Opt-in morning and evening daily review"
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
        scrollToAndTap(app.buttons["task-reschedule-relative-due-disclosure"], in: app)

        let relative = app.textFields["task-reschedule-relative-due-date"]
        scrollToAndTap(relative, in: app)
        relative.typeText("in 2 days")
        scrollToAndTap(app.buttons["task-reschedule-relative-due-apply"], in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["task-reschedule-save"].tap()
        XCTAssertTrue(relative.waitForNonExistence(timeout: 8))

        let todayID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        XCTAssertTrue(
            app.descendants(matching: .any)["daily-review-task-\(todayID)"]
                .waitForExistence(timeout: 8)
        )
        let taskScreenshot = XCTAttachment(screenshot: app.screenshot())
        taskScreenshot.name = "Morning review decision card"
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
        XCTAssertTrue(
            app.descendants(matching: .any)["daily-review-summary-closing"]
                .waitForExistence(timeout: 8)
        )
        app.buttons["daily-review-finish"].tap()

        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        openDailyReviewSettings(in: app)
        XCTAssertEqual(app.switches["daily-review-kickstart-enabled"].value as? String, "1")
        XCTAssertEqual(app.switches["daily-review-wrapUp-enabled"].value as? String, "1")
    }

    func testIntroductionCancellationAndAcknowledgementSurviveRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing", "-ui-testing-reset-workspace",
            "-daily-review.kickstart-minutes", "0",
        ]
        app.launch()
        defer { app.terminate() }

        openDailyReviewSettings(in: app)
        enableMorningReview(in: app)
        scrollToAndTap(app.buttons["daily-review-start-kickstart"], in: app)
        XCTAssertTrue(app.buttons["daily-review-begin"].waitForExistence(timeout: 8))
        app.buttons["daily-review-close"].tap()
        XCTAssertTrue(app.buttons["daily-review-prompt-kickstart"].waitForExistence(timeout: 8))

        app.terminate()
        app.launchArguments = ["-ui-testing", "-daily-review.kickstart-minutes", "0"]
        app.launch()
        let prompt = app.buttons["daily-review-prompt-kickstart"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.tap()
        let begin = app.buttons["daily-review-begin"]
        XCTAssertTrue(begin.waitForExistence(timeout: 8), "Cancel must not acknowledge the introduction")
        begin.tap()
        let firstDecision = app.buttons["daily-review-keep-01ARZ3NDEKTSV4RRFFQ69G5FAW"]
        XCTAssertTrue(firstDecision.waitForExistence(timeout: 8))
        app.buttons["daily-review-close"].tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 8), "Acknowledgement must not finish the review")

        app.terminate()
        app.launch()
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.tap()
        XCTAssertTrue(firstDecision.waitForExistence(timeout: 8))
        XCTAssertFalse(begin.exists, "Subsequent entry must not require a second start decision")
    }

    func testHelpPreservesProgressAndKeepLeavesTasksUnchangedAcrossRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace"]
        app.launch()
        defer { app.terminate() }

        let taskIDs = ["01ARZ3NDEKTSV4RRFFQ69G5FAW", "01ARZ3NDEKTSV4RRFFQ69G5FAV"]
        var originalLabels: [String: String] = [:]
        for taskID in taskIDs {
            let row = app.buttons["task-row-\(taskID)"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            originalLabels[taskID] = row.label
        }
        openDailyReviewSettings(in: app)
        enableMorningReview(in: app)
        scrollToAndTap(app.buttons["daily-review-start-kickstart"], in: app)
        scrollToAndTap(app.buttons["daily-review-begin"], in: app)
        scrollToAndTap(app.buttons["daily-review-keep-\(taskIDs[0])"], in: app)

        let secondDecision = app.buttons["daily-review-keep-\(taskIDs[1])"]
        XCTAssertTrue(secondDecision.waitForExistence(timeout: 8))
        let secondCard = app.descendants(matching: .any)["daily-review-task-\(taskIDs[1])"]
        let progress = secondCard.staticTexts["daily-review-progress"].label
        app.buttons["daily-review-help"].tap()
        scrollToAndTap(app.buttons["daily-review-help-return"], in: app)
        XCTAssertTrue(secondDecision.waitForExistence(timeout: 8))
        XCTAssertEqual(secondCard.staticTexts["daily-review-progress"].label, progress)

        app.buttons["daily-review-help"].tap()
        let closeHelp = app.buttons["daily-review-help-close"]
        XCTAssertTrue(closeHelp.waitForExistence(timeout: 8))
        closeHelp.tap()
        XCTAssertTrue(secondDecision.waitForExistence(timeout: 8))
        secondDecision.tap()
        let finish = app.buttons["daily-review-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 8))
        let counts = app.staticTexts["0 finished, 0 rescheduled, and 2 kept."]
        XCTAssertTrue(counts.exists)
        app.buttons["daily-review-help"].tap()
        scrollToAndTap(app.buttons["daily-review-help-return"], in: app)
        XCTAssertTrue(finish.waitForExistence(timeout: 8))
        XCTAssertTrue(counts.exists, "Help must preserve decisions and the closing page")
        app.buttons["daily-review-close"].tap()

        for taskID in taskIDs {
            let row = app.buttons["task-row-\(taskID)"]
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            XCTAssertEqual(row.label, originalLabels[taskID])
        }
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        for taskID in taskIDs {
            let row = app.buttons["task-row-\(taskID)"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            XCTAssertEqual(row.label, originalLabels[taskID], "Keep must not change a persisted task or schedule")
        }
    }

    func testEmptyFirstReviewAcknowledgesIntroductionWithoutFinishingAndResetRestoresIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing", "-ui-testing-reset-workspace",
            "-daily-review.kickstart-minutes", "0",
        ]
        app.launch()
        defer { app.terminate() }
        for taskID in ["01ARZ3NDEKTSV4RRFFQ69G5FAW", "01ARZ3NDEKTSV4RRFFQ69G5FAV"] {
            scrollToAndTap(app.buttons["task-toggle-completion-\(taskID)"], in: app)
            XCTAssertTrue(app.buttons["task-row-\(taskID)"].waitForNonExistence(timeout: 8))
        }

        openDailyReviewSettings(in: app)
        enableMorningReview(in: app)
        scrollToAndTap(app.buttons["daily-review-start-kickstart"], in: app)
        scrollToAndTap(app.buttons["daily-review-begin"], in: app)
        XCTAssertTrue(app.buttons["daily-review-finish"].waitForExistence(timeout: 8))
        app.buttons["daily-review-close"].tap()
        let prompt = app.buttons["daily-review-prompt-kickstart"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 8), "Seeing an empty summary must not finish the review")

        app.terminate()
        app.launchArguments = ["-ui-testing", "-daily-review.kickstart-minutes", "0"]
        app.launch()
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.tap()
        let finish = app.buttons["daily-review-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["daily-review-begin"].exists)
        finish.tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 8))

        app.terminate()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace"]
        app.launch()
        openDailyReviewSettings(in: app)
        enableMorningReview(in: app)
        scrollToAndTap(app.buttons["daily-review-start-kickstart"], in: app)
        XCTAssertTrue(app.buttons["daily-review-begin"].waitForExistence(timeout: 8))
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

    private func enableMorningReview(in app: XCUIApplication) {
        let toggle = app.switches["daily-review-kickstart-enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
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
