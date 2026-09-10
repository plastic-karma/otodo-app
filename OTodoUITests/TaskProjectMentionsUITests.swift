import XCTest

@MainActor
final class TaskProjectMentionsUITests: XCTestCase {
    func testNameAndNotesCompletionsAssignBothProjectsAfterOfflineRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace"]
        app.launch()
        XCTAssertTrue(app.buttons["task-filter-active"].waitForExistence(timeout: 10))
        app.buttons["task-filter-active"].tap()
        app.buttons["task-add"].tap()

        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText("Prepare #wo")
        let work = app.buttons["task-editor-name-project-suggestion-work"]
        XCTAssertTrue(work.waitForExistence(timeout: 8))
        work.tap()
        name.typeText(" report\n")
        let title = "Prepare #work report"
        XCTAssertEqual(name.value as? String, title)

        let notes = app.textViews["task-editor-notes"]
        app.revealTaskEditorElement(notes)
        notes.tap()
        notes.typeText("Café discussion #ho")
        let home = app.buttons["task-editor-notes-project-suggestion-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 8))
        home.tap()
        notes.typeText("\nKeep **Markdown** and person@example.com intact.")
        let body = "Café discussion #home\nKeep **Markdown** and person@example.com intact."
        XCTAssertEqual(notes.value as? String, body)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Project mentions complete in task name and multiline notes"
        preview.lifetime = .keepAlways
        add(preview)
        let done = app.buttons["task-editor-keyboard-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["task-editor-save"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 10))

        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["task-filter-active"].waitForExistence(timeout: 10))
        app.buttons["task-filter-active"].tap()
        let row = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "task-row-", title + ". State:"
        )).firstMatch
        for project in ["work", "home"] {
            app.buttons["project-sidebar-toggle"].tap()
            let filter = app.buttons["project-filter-\(project)"]
            XCTAssertTrue(filter.waitForExistence(timeout: 8))
            filter.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 8), "The saved task must belong to \(project), not merely display a mention")
        }
        row.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertEqual(name.value as? String, title)
        app.revealTaskEditorElement(notes)
        XCTAssertEqual(notes.value as? String, body)
        let restored = XCTAttachment(screenshot: app.screenshot())
        restored.name = "Mentioned projects and original prose persist offline"
        restored.lifetime = .keepAlways
        add(restored)
    }
}
