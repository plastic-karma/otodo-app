import Foundation
import XCTest

@MainActor
final class TaskCalendarUITests: XCTestCase {
    func testCalendarDayAndMonthFilteringCreatesExactDateThatSurvivesOfflineRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-light"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["task-filter-active"].waitForExistence(timeout: 10))
        app.buttons["task-filter-active"].tap()
        let today = calendar.startOfDay(for: .now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let monthStart = calendar.dateInterval(of: .month, for: today)!.start
        let destination = calendar.date(byAdding: .month, value: 2, to: monthStart)!

        openCalendar(in: app)
        tap("calendar-today", in: app)
        assertVisible("Seed todo", due: today, in: app)
        XCTAssertFalse(row("Future todo", in: app).exists)
        XCTAssertFalse(row("Undated todo", in: app).exists)

        selectDate(tomorrow, relativeTo: today, in: app)
        assertVisible("Future todo", due: tomorrow, in: app)
        XCTAssertFalse(row("Seed todo", in: app).exists, "Changing the day must filter rows, not only highlight a cell")

        tap("calendar-today", in: app)
        tap("calendar-next-month", in: app)
        tap("calendar-next-month", in: app)
        assertNoTasks(in: app)
        // No day tap: month navigation itself must select the destination's first day.
        create("Calendar field notes", andAnother: "Calendar followup", in: app)
        assertVisible("Calendar field notes", due: destination, in: app)
        assertVisible("Calendar followup", due: destination, in: app)
        tap("calendar-previous-month", in: app)
        assertNoTasks(in: app)
        tap("calendar-next-month", in: app)
        assertVisible("Calendar field notes", due: destination, in: app)

        let adjacentDay = calendar.date(byAdding: .day, value: 1, to: destination)!
        tap("calendar-day-\(dateString(adjacentDay))", in: app)
        assertNoTasks(in: app)
        tap("calendar-day-\(dateString(destination))", in: app)
        assertVisible("Calendar field notes", due: destination, in: app)
        reveal(app.buttons["calendar-day-\(dateString(destination))"], in: app)
        capture("Calendar · Saved future day · light", in: app)
        tap("calendar-today", in: app)
        assertVisible("Seed todo", due: today, in: app)
        XCTAssertFalse(row("Calendar field notes", in: app).exists)

        app.terminate()
        app.launchArguments = ["-ui-testing", "-ui-testing-light"]
        app.launch()
        XCTAssertTrue(app.buttons["task-filter-active"].waitForExistence(timeout: 10))
        app.buttons["task-filter-active"].tap()
        openCalendar(in: app)
        selectDate(destination, relativeTo: today, in: app)
        assertVisible("Calendar field notes", due: destination, in: app)
        assertVisible("Calendar followup", due: destination, in: app)
        XCTAssertFalse(row("Seed todo", in: app).exists)
        reveal(row("Calendar field notes", in: app), in: app)
        row("Calendar field notes", in: app).tap()
        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertEqual(name.value as? String, "Calendar field notes", "The offline row must open the saved todo")
    }

    func testCalendarProjectScopeAndUndatedCompletionAtAccessibilityTextSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["task-filter-active"].waitForExistence(timeout: 10))
        app.buttons["task-filter-active"].tap()
        let today = calendar.startOfDay(for: .now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        selectProject("work", in: app)
        openCalendar(in: app)
        tap("calendar-today", in: app)
        assertNoTasks(in: app)
        selectDate(tomorrow, relativeTo: today, in: app)
        assertVisible("Future todo", due: tomorrow, in: app)
        tap("calendar-no-date", in: app)
        assertVisible("Undated todo", due: nil, in: app)
        XCTAssertFalse(row("Future todo", in: app).exists)
        reveal(app.buttons["calendar-no-date"], in: app)
        capture("Calendar · Scoped no date · dark accessibility text", in: app)

        selectProject("home", in: app)
        tap("calendar-no-date", in: app)
        assertNoTasks(in: app)
        create("Home filing", in: app)
        assertVisible("Home filing", due: nil, in: app)
        XCTAssertFalse(row("Undated todo", in: app).exists, "No date must retain project scope")
        let savedID = String(row("Home filing", in: app).identifier.dropFirst("task-row-".count))
        tap("task-toggle-completion-\(savedID)", in: app)
        XCTAssertTrue(row("Home filing", in: app).waitForNonExistence(timeout: 8))
        assertNoTasks(in: app)

        selectProject("work", in: app)
        tap("calendar-no-date", in: app)
        assertVisible("Undated todo", due: nil, in: app)
        XCTAssertFalse(row("Home filing", in: app).exists)
        selectProject("home", in: app)
        selectDate(yesterday, relativeTo: today, in: app)
        assertVisible("Overdue todo", due: yesterday, in: app)
        XCTAssertFalse(row("Completed overdue todo", in: app).exists, "Calendar must exclude terminal work even on its due day")
        XCTAssertFalse(row("Future todo", in: app).exists)
        reveal(app.buttons["calendar-day-\(dateString(yesterday))"], in: app)
        capture("Calendar · Scoped dated work · dark accessibility text", in: app)
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .autoupdatingCurrent
        return value
    }

    private func dateString(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private func openCalendar(in app: XCUIApplication) {
        tap("project-sidebar-toggle", in: app)
        tapSidebar("upcoming-open", in: app)
        let segment = app.segmentedControls["upcoming-layout"].buttons["Calendar"]
        reveal(segment, in: app)
        segment.tap()
        XCTAssertTrue(app.buttons["calendar-today"].waitForExistence(timeout: 8))
    }

    private func selectProject(_ project: String, in app: XCUIApplication) {
        tap("project-sidebar-toggle", in: app)
        tapSidebar("project-filter-\(project)", in: app)
    }

    private func tapSidebar(_ identifier: String, in app: XCUIApplication) {
        let sidebar = app.descendants(matching: .any).matching(identifier: "project-sidebar").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 8))
        let filter = app.buttons[identifier]
        XCTAssertTrue(filter.waitForExistence(timeout: 8))
        for _ in 0..<5 where !filter.isHittable { sidebar.swipeUp(velocity: .slow) }
        for _ in 0..<5 where !filter.isHittable { sidebar.swipeDown(velocity: .slow) }
        XCTAssertTrue(filter.isHittable)
        filter.tap()
    }

    private func selectDate(_ date: Date, relativeTo today: Date, in app: XCUIApplication) {
        tap("calendar-today", in: app)
        let origin = calendar.dateInterval(of: .month, for: today)!.start
        let destination = calendar.dateInterval(of: .month, for: date)!.start
        let months = calendar.dateComponents([.month], from: origin, to: destination).month!
        for _ in 0..<abs(months) {
            tap(months > 0 ? "calendar-next-month" : "calendar-previous-month", in: app)
        }
        tap("calendar-day-\(dateString(date))", in: app)
    }

    private func create(_ title: String, andAnother nextTitle: String? = nil, in app: XCUIApplication) {
        let add = app.buttons["task-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: add)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed)
        add.tap()
        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText(title)
        if let nextTitle {
            app.buttons["task-editor-save-another"].tap()
            let confirmation = app.descendants(matching: .any)
                .matching(identifier: "task-editor-saved-confirmation").firstMatch
            XCTAssertTrue(confirmation.waitForExistence(timeout: 8))
            name.typeText(nextTitle)
        }
        XCTAssertTrue(app.buttons["task-editor-save"].isEnabled)
        app.buttons["task-editor-save"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 8))
    }

    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "task-row-", "\(title). State:"
        )).firstMatch
    }

    private func assertVisible(_ title: String, due: Date?, in app: XCUIApplication) {
        let task = row(title, in: app)
        reveal(task, in: app)
        if let due {
            XCTAssertTrue(task.label.contains("Due: \(dateString(due))"), "The todo must have the exact selected civil date")
        } else {
            XCTAssertFalse(task.label.contains("Due:"), "No date capture must remain undated")
        }
    }

    private func assertNoTasks(in app: XCUIApplication) {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-row-"))
        let list = app.descendants(matching: .any).matching(identifier: "task-list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 8))
        // Inspect the row area too: a lazy list below the month grid must not hide a filtering failure.
        for _ in 0..<4 {
            XCTAssertEqual(rows.count, 0, "This calendar day and project must have no active todos")
            list.swipeUp(velocity: .slow)
        }
        XCTAssertEqual(rows.count, 0)
    }

    private func tap(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        if app.navigationBars.buttons[identifier].exists {
            XCTAssertTrue(button.isHittable)
        } else {
            reveal(button, in: app)
        }
        button.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let list = app.descendants(matching: .any).matching(identifier: "task-list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 8))
        let navigation = app.navigationBars.firstMatch
        let sync = app.descendants(matching: .any).matching(identifier: "sync-status").firstMatch
        let add = app.buttons["task-add"]

        func viewport() -> CGRect {
            let frame = list.frame.intersection(app.frame)
            let top = max(frame.minY, navigation.frame.maxY) + 8
            var bottom = frame.maxY - 8
            if sync.exists { bottom = min(bottom, sync.frame.minY - 8) }
            if add.exists { bottom = min(bottom, add.frame.minY - 8) }
            return CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, bottom - top))
        }
        func isUnobscured() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let visible = viewport()
            let frame = element.frame
            return frame.minY >= visible.minY && frame.maxY <= visible.maxY
                && frame.midX > visible.minX && frame.midX < visible.maxX
        }

        for attempt in 0..<16 {
            if isUnobscured() { return }
            let visible = viewport()
            guard visible.height > 80 else { break }
            revealCalendarColumn(element, in: app, viewport: visible)
            if isUnobscured() { return }
            let distance: CGFloat
            if element.exists {
                distance = max(-visible.height * 0.4, min(visible.height * 0.4, visible.midY - element.frame.midY))
            } else {
                distance = visible.height * (attempt < 8 ? -0.4 : 0.4)
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: visible.maxX - 6, dy: visible.midY))
            let end = origin.withOffset(CGVector(dx: visible.maxX - 6, dy: visible.midY + distance))
            start.press(
                forDuration: 0.05, thenDragTo: end,
                withVelocity: .slow, thenHoldForDuration: 0.2
            )
        }
        XCTAssertTrue(element.exists, "The calendar must expose the requested control or todo")
        XCTAssertTrue(isUnobscured(), "Calendar content must be clear of navigation and fixed bottom controls")
    }

    private func revealCalendarColumn(_ element: XCUIElement, in app: XCUIApplication, viewport: CGRect) {
        guard element.exists, element.identifier.hasPrefix("calendar-day-") else { return }
        let grid = app.scrollViews["calendar-grid"]
        guard grid.exists, grid.isHittable else { return }
        for _ in 0..<6 {
            let viewport = grid.frame.intersection(viewport)
            guard viewport.width > 80, viewport.height > 20 else { break }
            let targetX = element.frame.midX
            guard targetX < viewport.minX || targetX > viewport.maxX else { break }
            let distance = max(-viewport.width * 0.4, min(viewport.width * 0.4, viewport.midX - targetX))
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX, dy: viewport.midY))
            let end = origin.withOffset(CGVector(dx: viewport.midX + distance, dy: viewport.midY))
            // Match editor scrolling: stop before lifting so momentum cannot skip a column.
            start.press(
                forDuration: 0.05, thenDragTo: end,
                withVelocity: .slow, thenHoldForDuration: 0.2
            )
            if abs(element.frame.midX - targetX) < 1 { break }
        }
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
