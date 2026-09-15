import XCTest

@MainActor
final class TaskProjectMentionsUITests: XCTestCase {
    func testNameAndNotesCompletionsMergeProjectsAndTagsAcrossCreateEditAndOfflineRelaunch() {
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
        name.typeText(" @fo")
        let focus = app.buttons["task-editor-name-tag-suggestion-focus"]
        XCTAssertTrue(focus.waitForExistence(timeout: 8))
        focus.tap()
        name.typeText(" report\n")
        let title = "Prepare #work @focus report"
        XCTAssertEqual(name.value as? String, title)

        let notes = app.textViews["task-editor-notes"]
        app.revealTaskEditorElement(notes)
        notes.tap()
        notes.typeText("Café discussion #ho")
        let home = app.buttons["task-editor-notes-project-suggestion-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 8))
        home.tap()
        notes.typeText(" @ho")
        let homeTag = app.buttons["task-editor-notes-tag-suggestion-home"]
        XCTAssertTrue(homeTag.waitForExistence(timeout: 8))
        homeTag.tap()
        notes.typeText("\nKeep **Markdown**, person@example.com, #unknown and @unknown intact.")
        let body = "Café discussion #home @home\nKeep **Markdown**, person@example.com, #unknown and @unknown intact."
        XCTAssertEqual(notes.value as? String, body)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Project mentions complete in task name and multiline notes"
        preview.lifetime = .keepAlways
        add(preview)
        let done = app.buttons["task-editor-keyboard-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let tags = app.textFields["task-editor-tags"]
        revealTags(in: app)
        tags.tap()
        tags.typeText("manual\n")
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
        revealTags(in: app)
        XCTAssertEqual(tags.value as? String, "manual, focus, home")
        XCTAssertEqual(app.buttons["work project"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["home project"].value as? String, "Selected")
        let restored = XCTAttachment(screenshot: app.screenshot())
        restored.name = "Mentioned projects and original prose persist offline"
        restored.lifetime = .keepAlways
        add(restored)

        // Removing prose mentions must not discard metadata already saved on this task.
        app.revealTaskEditorElement(name)
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: title.count))
        name.typeText("Edited mentions\n")
        app.revealTaskEditorElement(notes)
        notes.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99)).tap()
        notes.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: body.count))
        notes.typeText("Leave @work and #focus as prose, not reversed assignments.")
        done.tap()
        app.buttons["task-editor-save"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 8))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["task-filter-active"].waitForExistence(timeout: 10))
        app.buttons["task-filter-active"].tap()
        let edited = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
            "task-row-", "Edited mentions. State:"
        )).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 8))
        edited.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        revealTags(in: app)
        XCTAssertEqual(tags.value as? String, "manual, focus, home")
        XCTAssertEqual(app.buttons["work project"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["home project"].value as? String, "Selected")
    }

    private func revealTags(in app: XCUIApplication) {
        let disclosure = app.buttons["task-editor-details"]
        app.revealTaskEditorElement(disclosure)
        if disclosure.value as? String != "Expanded" { disclosure.tap() }
        app.revealTaskEditorElement(app.textFields["task-editor-tags"])
    }
}
