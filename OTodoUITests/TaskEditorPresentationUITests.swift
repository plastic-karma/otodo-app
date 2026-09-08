import Foundation
import XCTest

final class TaskEditorPresentationUITests: XCTestCase {
    @MainActor
    func testFocusedEditorPreservesHiddenDetailsInLightAndDark() throws {
        continueAfterFailure = false
        executionTimeAllowance = 600
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-\(appearance)"]
            app.launch()
            selectActive(in: app)
            app.buttons["task-add"].tap()
            let name = app.textFields["task-editor-name"]
            let notes = app.textViews["task-editor-notes"]
            XCTAssertTrue(name.waitForExistence(timeout: 8))
            XCTAssertTrue(notes.isHittable, "Notes must be immediately usable without opening details")
            XCTAssertFalse(app.textFields["task-editor-tags"].isHittable)
            attachScreenshot(in: app, name: "Focused editor — empty new — \(appearance)")

            name.tap()
            name.typeText("Weekend plan tomorrow")
            notes.tap()
            notes.typeText("## Make time\n- Walk by the water\n- Read a chapter")
            openPanel("details", revealing: "task-editor-tags", in: app)
            app.buttons["work project"].tap()
            let tags = app.textFields["task-editor-tags"]
            tags.tap()
            tags.typeText("focus")
            closePanel("details", in: app)
            openPanel("schedule", revealing: "task-editor-repeat", in: app)
            app.buttons["task-editor-repeat"].tap()
            app.buttons["Daily"].tap()
            closePanel("schedule", in: app)
            dismissKeyboardAndReturnToTop(in: app)
            attachScreenshot(in: app, name: "Focused editor — populated new — \(appearance)")
            save(in: app)

            app.terminate()
            app.launchArguments.removeAll { $0 == "-ui-testing-reset-workspace" }
            app.launch()
            selectActive(in: app)
            openWeekend(in: app)
            XCTAssertEqual(name.value as? String, "Weekend plan")
            XCTAssertEqual(notes.value as? String, "## Make time\n- Walk by the water\n- Read a chapter")
            XCTAssertFalse(tags.isHittable)
            attachScreenshot(in: app, name: "Focused editor — populated edit — \(appearance)")

            // Saving just the visible title must not clear unopened imported metadata.
            name.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
            name.typeText(" away\n")
            save(in: app)
            app.terminate()
            app.launch()
            selectActive(in: app)
            openWeekend(in: app)
            XCTAssertEqual(name.value as? String, "Weekend plan away")
            XCTAssertEqual(notes.value as? String, "## Make time\n- Walk by the water\n- Read a chapter")
            openPanel("details", revealing: "task-editor-tags", in: app)
            XCTAssertEqual(tags.value as? String, "focus")
            XCTAssertEqual(app.buttons["work project"].value as? String, "Selected")
            app.buttons["Cancel"].tap()
            XCTAssertTrue(name.waitForNonExistence(timeout: 8))
            let row = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                "task-row-", "Weekend plan away"
            )).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            let dueRange = try XCTUnwrap(row.label.range(of: "Due: "))
            let due = String(row.label[dueRange.upperBound...].prefix(10))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .autoupdatingCurrent
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            let next = try XCTUnwrap(calendar.date(
                byAdding: .day, value: 1, to: try XCTUnwrap(formatter.date(from: due))
            ))
            let id = String(row.identifier.dropFirst("task-row-".count))
            app.buttons["task-toggle-completion-\(id)"].tap()
            let advanced = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "label CONTAINS %@ AND label CONTAINS %@",
                    "Due: \(formatter.string(from: next))", "State: Pending"
                ), object: row
            )
            XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 8), .completed,
                           "Completing the preserved daily rule must advance the same task by one day")
            app.terminate()
        }
    }

    @MainActor
    func testCollapsingScheduleKeepsPendingDateAndInvalidRecurrenceEdits() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace"]
        app.launch()
        selectActive(in: app)
        app.buttons["task-add"].tap()
        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText("Review schedule\n")
        openPanel("schedule", revealing: "task-editor-relative-due-date", in: app)
        attachScreenshot(in: app, name: "Recurrence reset preserves Stats history")
        let relative = app.textFields["task-editor-relative-due-date"]
        relative.tap()
        relative.typeText("in 6 hours")
        let save = app.buttons["task-editor-save"]
        XCTAssertFalse(save.isEnabled)
        closePanel("schedule", in: app)
        XCTAssertFalse(save.isEnabled, "Collapsing must not silently discard an unapplied date")
        openPanel("schedule", revealing: "task-editor-relative-due-date", in: app)
        XCTAssertEqual(relative.value as? String, "in 6 hours")
        app.buttons["task-editor-relative-due-apply"].tap()
        scrollTo(app.buttons["task-editor-repeat"], in: app)
        app.buttons["task-editor-repeat"].tap()
        app.buttons["Daily"].tap()
        let interval = app.textFields["task-editor-repeat-interval"]
        scrollTo(interval, in: app)
        interval.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        interval.typeText(XCUIKeyboardKey.delete.rawValue + "0")
        XCTAssertFalse(save.isEnabled)
        closePanel("schedule", in: app)
        XCTAssertFalse(save.isEnabled, "An invalid hidden repeat edit must continue to block saving")
        openPanel("schedule", revealing: "task-editor-repeat-interval", in: app)
        XCTAssertEqual(interval.value as? String, "0")
        interval.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        interval.typeText(XCUIKeyboardKey.delete.rawValue + "2")
        XCTAssertTrue(save.isEnabled, "Correcting the retained invalid interval must restore saving")
    }

    @MainActor
    private func selectActive(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["task-filter-active"].waitForExistence(timeout: 8))
        app.buttons["task-filter-active"].tap()
    }

    @MainActor
    private func openWeekend(in app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
            "task-row-", "Weekend plan"
        )).firstMatch
        let list = app.descendants(matching: .any).matching(identifier: "task-list").firstMatch
        for _ in 0..<8 {
            if row.exists && row.isHittable { break }
            list.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        XCTAssertTrue(app.textFields["task-editor-name"].waitForExistence(timeout: 8))
    }

    @MainActor
    private func save(in app: XCUIApplication) {
        let editor = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
        XCTAssertTrue(app.buttons["task-editor-save"].isEnabled)
        app.buttons["task-editor-save"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 8))
    }

    @MainActor
    private func openPanel(_ panel: String, revealing identifier: String, in app: XCUIApplication) {
        let disclosure = app.buttons["task-editor-\(panel)"]
        scrollTo(disclosure, in: app)
        if disclosure.value as? String != "Expanded" { disclosure.tap() }
        scrollTo(app.descendants(matching: .any).matching(identifier: identifier).firstMatch, in: app)
    }

    @MainActor
    private func closePanel(_ panel: String, in app: XCUIApplication) {
        let disclosure = app.buttons["task-editor-\(panel)"]
        scrollTo(disclosure, in: app)
        if disclosure.value as? String == "Expanded" { disclosure.tap() }
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        app.revealTaskEditorElement(element)
    }

    @MainActor
    private func dismissKeyboardAndReturnToTop(in app: XCUIApplication) {
        let name = app.textFields["task-editor-name"]
        scrollTo(name, in: app)
        name.tap()
        name.typeText("\n")
    }

    @MainActor
    private func attachScreenshot(in app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
