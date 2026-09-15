import XCTest

@MainActor
final class ProjectEditingUITests: XCTestCase {
    func testCancelAndOfflineRenameKeepSlugAndTaskMembershipAcrossRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-light"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["project-sidebar-toggle"].waitForExistence(timeout: 10))

        openProjectEditor(in: app)
        replaceName("Discard this change", in: app)
        app.navigationBars["Edit Project"].buttons["Cancel"].tap()
        openProjectEditor(in: app)
        XCTAssertEqual(app.textFields["project-editor-name"].value as? String, "Home")
        replaceName("Household plans", in: app)
        let notes = app.textViews["project-editor-notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 8))
        notes.tap()
        notes.typeText("# Goals\n\nKeep **Markdown** and [[links]].")
        app.buttons["project-editor-save"].tap()
        XCTAssertTrue(app.textFields["project-editor-name"].waitForNonExistence(timeout: 8))

        app.terminate()
        app.launchArguments = ["-ui-testing", "-ui-testing-light"]
        app.launch()
        XCTAssertTrue(app.buttons["project-sidebar-toggle"].waitForExistence(timeout: 10))
        openProjectEditor(in: app)
        XCTAssertEqual(app.textFields["project-editor-name"].value as? String, "Household plans")
        XCTAssertEqual(notes.value as? String, "# Goals\n\nKeep **Markdown** and [[links]].")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Offline project editing preserves its slug and Markdown notes"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.navigationBars["Edit Project"].buttons["Cancel"].tap()
        app.buttons["task-filter-all"].tap()
        let row = app.buttons["task-row-01ARZ3NDEKTSV4RRFFQ69G5FAV"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(row.label.contains("Projects: home"))
    }

    private func openProjectEditor(in app: XCUIApplication) {
        app.buttons["project-sidebar-toggle"].tap()
        let actions = app.buttons["project-actions-home"]
        XCTAssertTrue(actions.waitForExistence(timeout: 8))
        let sidebar = app.descendants(matching: .any).matching(identifier: "project-sidebar").firstMatch
        for _ in 0..<5 where !actions.isHittable { sidebar.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(actions.isHittable)
        actions.tap()
        let edit = app.buttons["project-edit-home"]
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        edit.tap()
        XCTAssertTrue(app.textFields["project-editor-name"].waitForExistence(timeout: 8))
    }

    private func replaceName(_ value: String, in app: XCUIApplication) {
        let name = app.textFields["project-editor-name"]
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String ?? "").count) + value)
    }
}
