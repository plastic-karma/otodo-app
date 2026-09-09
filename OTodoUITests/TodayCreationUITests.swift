import Foundation
import XCTest

final class TodayCreationUITests: XCTestCase {
    @MainActor
    func testTodayCreationPersistsAndExplicitDateWinsWithoutLeakingToOtherViews() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace"]
        app.launch()
        defer { app.terminate() }

        let today = app.buttons["task-filter-today"]
        XCTAssertTrue(today.waitForExistence(timeout: 8))
        XCTAssertTrue(today.isSelected)
        create("Finish draft", in: app)
        let created = row("Finish draft", in: app)
        XCTAssertTrue(created.waitForExistence(timeout: 8), "A new Today todo must stay visible after saving")
        XCTAssertTrue(created.label.contains("Due: \(dateString(dayOffset: 0))"))
        XCTAssertFalse(created.label.contains(" at "), "Today supplies a date, not an exact time")

        let snapshot = XCTAttachment(screenshot: app.screenshot())
        snapshot.name = "New todo remains in Today"
        snapshot.lifetime = .keepAlways
        add(snapshot)

        create("Call editor tomorrow", in: app)
        app.buttons["task-filter-active"].tap()
        let tomorrow = row("Call editor", in: app)
        reveal(tomorrow, in: app)
        XCTAssertTrue(tomorrow.waitForExistence(timeout: 8))
        XCTAssertTrue(tomorrow.label.contains("Due: \(dateString(dayOffset: 1))"), "An explicit phrase overrides the view's default date")

        create("Someday review", in: app)
        let undated = row("Someday review", in: app)
        reveal(undated, in: app)
        XCTAssertTrue(undated.waitForExistence(timeout: 8))
        XCTAssertFalse(undated.label.contains("Due:"), "Active must not reuse Today's date default")

        // Upcoming can retain Today as its selected filter; the mode must still win.
        let list = app.descendants(matching: .any).matching(identifier: "task-list").firstMatch
        for _ in 0..<6 where !today.isHittable { list.swipeDown() }
        app.buttons["task-filter-today"].tap()
        app.buttons["project-sidebar-toggle"].tap()
        let upcoming = app.buttons["upcoming-open"]
        XCTAssertTrue(upcoming.waitForExistence(timeout: 8))
        upcoming.tap()
        create("Weekly planning", in: app)

        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(today.waitForExistence(timeout: 8))
        XCTAssertTrue(created.waitForExistence(timeout: 8), "Today's due date must survive offline relaunch")
        XCTAssertTrue(created.label.contains("Due: \(dateString(dayOffset: 0))"))
        XCTAssertFalse(tomorrow.exists)
        XCTAssertFalse(undated.exists)
        app.buttons["task-filter-active"].tap()
        let upcomingCreated = row("Weekly planning", in: app)
        reveal(upcomingCreated, in: app)
        XCTAssertTrue(upcomingCreated.waitForExistence(timeout: 8))
        XCTAssertFalse(upcomingCreated.label.contains("Due:"), "Upcoming creation must remain undated")
    }

    @MainActor
    func testTodayDefaultsSurviveRepeatedAndBulkCreation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["task-add"].waitForExistence(timeout: 8))
        app.buttons["task-add"].tap()
        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText("Rapid first tomorrow")
        app.buttons["task-editor-save-another"].tap()
        let confirmation = app.descendants(matching: .any).matching(identifier: "task-editor-saved-confirmation").firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 8))
        name.typeText("Rapid second")
        app.buttons["task-editor-save"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 8))
        XCTAssertTrue(row("Rapid second", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(row("Rapid second", in: app).label.contains("Due: \(dateString(dayOffset: 0))"))
        XCTAssertFalse(row("Rapid first", in: app).exists, "The previous explicit date must not carry into the next Today draft")

        app.buttons["task-add"].press(forDuration: 1.2)
        let bulk = app.buttons["task-add-menu-bulk"]
        XCTAssertTrue(bulk.waitForExistence(timeout: 8))
        bulk.tap()
        let text = app.textViews["task-bulk-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        text.tap()
        text.typeText("Batch default\nBatch explicit tomorrow")
        app.buttons["task-bulk-save"].tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 8))

        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        for title in ["Rapid second", "Batch default"] {
            let saved = row(title, in: app)
            XCTAssertTrue(saved.waitForExistence(timeout: 8))
            XCTAssertTrue(saved.label.contains("Due: \(dateString(dayOffset: 0))"))
        }
        XCTAssertFalse(row("Batch explicit", in: app).exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Today defaults in repeated and bulk entry"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func create(_ name: String, in app: XCUIApplication) {
        let add = app.buttons["task-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: add
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed)
        add.tap()
        let title = app.textFields["task-editor-name"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap()
        title.typeText(name)
        let save = app.buttons["task-editor-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 8))
    }

    @MainActor
    private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
            "task-row-", "\(name). State: Pending"
        )).firstMatch
    }

    @MainActor
    private func reveal(_ row: XCUIElement, in app: XCUIApplication) {
        if row.waitForExistence(timeout: 2) { return }
        let list = app.descendants(matching: .any).matching(identifier: "task-list").firstMatch
        for _ in 0..<6 where !row.exists { list.swipeUp() }
        for _ in 0..<6 where !row.exists { list.swipeDown() }
    }

    private func dateString(dayOffset: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let date = calendar.date(byAdding: .day, value: dayOffset, to: .now)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }
}
