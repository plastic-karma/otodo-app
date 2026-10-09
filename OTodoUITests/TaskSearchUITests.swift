import XCTest

@MainActor
final class TaskSearchUITests: XCTestCase {
    func testSearchFindsNotesAndCompletedTodosAcrossTheWorkspaceThenRestoresToday() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-light"]
        app.launch()
        defer { app.terminate() }

        let seed = app.buttons["task-row-01ARZ3NDEKTSV4RRFFQ69G5FAV"]
        let future = app.buttons["task-row-01ARZ3NDEKTSV4RRFFQ69G5FAX"]
        let completed = app.buttons["task-row-01ARZ3NDEKTSV4RRFFQ69G5FAZ"]
        XCTAssertTrue(seed.waitForExistence(timeout: 10))
        XCTAssertFalse(future.exists)
        XCTAssertFalse(completed.exists)

        app.buttons["task-search-open"].tap()
        let search = app.textFields["task-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("invoice 123")
        XCTAssertTrue(future.waitForExistence(timeout: 8), "Search must include Markdown notes outside Today")
        XCTAssertFalse(seed.exists)

        clear(search, in: app)
        search.typeText("completed overdue")
        XCTAssertTrue(completed.waitForExistence(timeout: 8), "Search must include terminal todos")
        XCTAssertTrue(completed.label.contains("Terminal state"), completed.label)
        XCTAssertFalse(seed.exists)

        clear(search, in: app)
        XCTAssertTrue(seed.waitForExistence(timeout: 8), "Clearing search must restore the prior Today view")
        XCTAssertFalse(future.exists)
        XCTAssertFalse(completed.exists)
    }

    private func clear(_ search: XCUIElement, in app: XCUIApplication) {
        let clearButton = app.buttons["task-search-clear"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 5))
        clearButton.tap()
        XCTAssertEqual(search.value as? String, "Search all todos")
    }
}
