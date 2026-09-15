import XCTest

@MainActor
final class TaskSearchUITests: XCTestCase {
    func testWorkspaceSearchOpensCompletedAndNotesMatchesThenReturnsToPriorProjectFilter() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-light"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["project-sidebar-toggle"].waitForExistence(timeout: 10))
        app.buttons["project-sidebar-toggle"].tap()
        let project = app.buttons["project-filter-work"]
        XCTAssertTrue(project.waitForExistence(timeout: 8))
        let sidebar = app.descendants(matching: .any).matching(identifier: "project-sidebar").firstMatch
        for _ in 0..<5 where !project.isHittable { sidebar.scrollViews.firstMatch.swipeUp() }
        project.tap()
        app.buttons["task-search-open"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("completed")
        let completed = app.buttons["task-row-01ARZ3NDEKTSV4RRFFQ69G5FAZ"]
        XCTAssertTrue(completed.waitForExistence(timeout: 8))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Workspace search finds completed tasks outside the selected project"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        completed.tap()
        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertEqual(name.value as? String, "Completed overdue todo")
        app.navigationBars.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 8))

        replaceQuery("invoice 123 focus", in: search)
        let notesMatch = app.buttons["task-row-01ARZ3NDEKTSV4RRFFQ69G5FAX"]
        XCTAssertTrue(notesMatch.waitForExistence(timeout: 8))
        notesMatch.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertEqual(name.value as? String, "Future todo")
        app.navigationBars.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 8))
        replaceQuery("no-such-search-result", in: search)
        let empty = app.descendants(matching: .any).matching(identifier: "task-search-empty").firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 8))
        // Native search cancellation restores the sheet toolbar before it can be dismissed.
        app.buttons["Close"].tap()
        let close = app.buttons["task-search-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        close.tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars["Work"].exists)
        XCTAssertTrue(app.buttons["task-filter-today"].isSelected)
        XCTAssertFalse(completed.exists)
    }

    private func replaceQuery(_ value: String, in search: XCUIElement) {
        search.tap()
        search.buttons["Clear text"].tap()
        search.typeText(value)
    }
}
