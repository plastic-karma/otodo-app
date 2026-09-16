import XCTest

@MainActor
final class ProjectEditingUITests: XCTestCase {
    func testProjectNameAndNotesPersistOfflineWithoutChangingSlug() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let resetArgument = "-ui-testing-reset-workspace"
        app.launchArguments = ["-ui-testing", resetArgument, "-ui-testing-light"]
        app.launch()
        defer { app.terminate() }

        openEditor(for: "home", in: app)
        let editor = app.descendants(matching: .any)
            .matching(identifier: "project-editor")
            .firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))

        let name = app.textFields["project-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertEqual(name.value as? String, "Home")
        name.tap()
        name.typeText(" Personal")

        let slug = app.staticTexts["project-editor-slug"]
        XCTAssertTrue(slug.waitForExistence(timeout: 8))
        XCTAssertTrue(
            slug.label.hasSuffix("home"),
            "Editing a display name must not rename the project slug: \(slug.label)"
        )

        let notes = app.textViews["project-editor-notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 8))
        notes.tap()
        notes.typeText("# Shared plans\nKeep this project context offline.")

        let save = app.buttons["project-editor-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))

        openSidebar(in: app)
        let renamed = app.buttons["project-filter-home"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 8))
        XCTAssertTrue(renamed.label.hasPrefix("Home Personal,"), renamed.label)
        app.buttons["project-sidebar-close"].tap()

        app.terminate()
        app.launchArguments.removeAll { $0 == resetArgument }
        app.launch()

        openSidebar(in: app)
        XCTAssertTrue(app.buttons["project-filter-home"].label.hasPrefix("Home Personal,"))
        app.buttons["project-actions-home"].tap()
        app.buttons["project-edit-home"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        XCTAssertEqual(name.value as? String, "Home Personal")
        XCTAssertEqual(notes.value as? String, "# Shared plans\nKeep this project context offline.")
        XCTAssertTrue(slug.label.hasSuffix("home"), slug.label)
    }

    private func openEditor(for slug: String, in app: XCUIApplication) {
        openSidebar(in: app)
        let actions = app.buttons["project-actions-\(slug)"]
        XCTAssertTrue(actions.waitForExistence(timeout: 8))
        actions.tap()
        let edit = app.buttons["project-edit-\(slug)"]
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        edit.tap()
    }

    private func openSidebar(in app: XCUIApplication) {
        if !app.buttons["project-sidebar-close"].exists {
            let toggle = app.buttons["project-sidebar-toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            toggle.tap()
        }
        XCTAssertTrue(app.buttons["project-sidebar-close"].waitForExistence(timeout: 8))
    }
}
