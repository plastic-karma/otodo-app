import XCTest

@MainActor
final class TaskProjectMentionsUITests: XCTestCase {
    func testNameAndNotesCompletionsAssignProjectsAndTagsAfterOfflineRelaunch() {
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
        name.typeText(" report @fo")
        let focus = app.buttons["task-editor-name-tag-suggestion-focus"]
        XCTAssertTrue(focus.waitForExistence(timeout: 8))
        focus.tap()
        name.typeText("\n")
        let title = "Prepare #work report @focus"
        XCTAssertEqual(name.value as? String, title)

        let notes = app.textViews["task-editor-notes"]
        app.revealTaskEditorElement(notes)
        notes.tap()
        notes.typeText("Café discussion #ho")
        let homeProject = app.buttons["task-editor-notes-project-suggestion-home"]
        XCTAssertTrue(homeProject.waitForExistence(timeout: 8))
        homeProject.tap()
        notes.typeText(" @ho")
        let homeTag = app.buttons["task-editor-notes-tag-suggestion-home"]
        XCTAssertTrue(homeTag.waitForExistence(timeout: 8))
        homeTag.tap()
        notes.typeText("\nKeep **Markdown** and person@example.com intact.")
        let body = "Café discussion #home @home\nKeep **Markdown** and person@example.com intact."
        XCTAssertEqual(notes.value as? String, body)
        XCTAssertEqual(
            app.descendants(matching: .any)["task-editor-detected-projects"].label,
            "Projects from #mentions: home, work"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["task-editor-detected-tags"].label,
            "Tags from @mentions: focus, home"
        )
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Project and tag mentions complete in task name and multiline notes"
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
        XCTAssertTrue(row.label.contains("Tags: focus, home"))
        row.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertEqual(name.value as? String, title)
        app.revealTaskEditorElement(notes)
        XCTAssertEqual(notes.value as? String, body)
        let details = app.buttons["task-editor-details"]
        app.revealTaskEditorElement(details)
        if details.value as? String != "Expanded" { details.tap() }
        let tags = app.textFields["task-editor-tags"]
        app.revealTaskEditorElement(tags)
        XCTAssertEqual(tags.value as? String, "focus, home")
        let restored = XCTAttachment(screenshot: app.screenshot())
        restored.name = "Mentioned projects, tags, and original prose persist offline"
        restored.lifetime = .keepAlways
        add(restored)
    }
}
