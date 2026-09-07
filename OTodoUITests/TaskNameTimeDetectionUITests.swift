import Foundation
import XCTest

final class TaskNameTimeDetectionUITests: XCTestCase {
    @MainActor
    func testNameClockKeepsSelectedCalendarDateAndPersistsAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace"]
        app.launch()
        defer { app.terminate() }
        let active = app.buttons["task-filter-active"]
        XCTAssertTrue(active.waitForExistence(timeout: 8))
        active.tap()
        app.buttons["task-add"].tap()
        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))

        let schedule = app.buttons["task-editor-schedule"]
        app.revealTaskEditorElement(schedule)
        schedule.tap()
        let relative = app.textFields["task-editor-relative-due-date"]
        app.revealTaskEditorElement(relative)
        relative.tap()
        relative.typeText("in 2 days")
        let apply = app.buttons["task-editor-relative-due-apply"]
        XCTAssertTrue(apply.isEnabled)
        let expectedDate = dateString(dayOffset: 2)
        apply.tap()

        app.revealTaskEditorElement(name)
        name.tap()
        name.typeText("Manual deadline at 2:45 pm")
        let detection = app.descendants(matching: .any)
            .matching(identifier: "task-editor-detected-due-date").firstMatch
        XCTAssertTrue(detection.waitForExistence(timeout: 8))
        XCTAssertTrue(detection.label.contains("\(expectedDate) at 14:45"), "A name clock must override the time without replacing the selected date with today")
        XCTAssertTrue(schedule.label.contains(expectedDate), "The schedule summary must show the same date that will be saved")
        XCTAssertTrue(schedule.label.contains("14:45"), "The schedule summary must include the detected exact time")
        let save = app.buttons["task-editor-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 8))

        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(active.waitForExistence(timeout: 8))
        active.tap()
        let saved = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
            "task-row-", "Manual deadline. State: Pending"
        )).firstMatch
        let list = app.descendants(matching: .any).matching(identifier: "task-list").firstMatch
        for _ in 0..<6 where !saved.exists { list.swipeUp() }
        for _ in 0..<6 where !saved.exists { list.swipeDown() }
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
        XCTAssertTrue(saved.label.contains("Due: \(expectedDate) at 14:45"))
        saved.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertEqual(name.value as? String, "Manual deadline")
        app.revealTaskEditorElement(schedule)
        schedule.tap()
        let time = app.switches["task-editor-due-time-toggle"]
        app.revealTaskEditorElement(time)
        XCTAssertEqual(time.value as? String, "1")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Name clock persisted with selected calendar date"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func dateString(dayOffset: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let date = calendar.date(byAdding: .day, value: dayOffset, to: .now)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }
}
