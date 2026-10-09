import Foundation
import XCTest

/// A repeatable visual survey, exported by CI's export_ui_snapshots option.
final class OTodoDesignScreenshots: XCTestCase {
    @MainActor
    func testCaptureSurfacesInLightAndDarkAppearance() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-\(appearance)",
            ]
            app.launch()
            XCTAssertTrue(app.buttons["task-add"].waitForExistence(timeout: 10))
            waitForTodos(in: app)
            capture("Survey · Today · \(appearance)", in: app)

            app.buttons["task-filter-active"].tap()
            XCTAssertTrue(app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "task-row-", "Future todo")
            ).firstMatch.waitForExistence(timeout: 5))
            capture("Survey · Active · \(appearance)", in: app)
            app.buttons["project-sidebar-toggle"].tap()
            XCTAssertTrue(app.buttons["project-filter-work"].waitForExistence(timeout: 5))
            capture("Survey · Workspace navigation · \(appearance)", in: app)
            app.buttons["sidebar-project-add"].tap()
            XCTAssertTrue(app.textFields["project-editor-name"].waitForExistence(timeout: 5))
            capture("Survey · Project creation · \(appearance)", in: app)
            app.buttons["Cancel"].tap()

            app.buttons["project-sidebar-toggle"].tap()
            app.buttons["settings-open"].tap()
            XCTAssertTrue(app.buttons["notification-settings"].waitForExistence(timeout: 5))
            capture("Survey · Settings · \(appearance)", in: app)
            app.buttons["notification-settings"].tap()
            XCTAssertTrue(app.buttons["reminder-settings-done"].waitForExistence(timeout: 5))
            app.buttons["reminder-settings-done"].tap()

            app.buttons["project-sidebar-toggle"].tap()
            app.buttons["sidebar-daily-review"].tap()
            app.buttons["sidebar-review-kickstart"].tap()
            XCTAssertTrue(app.buttons["daily-review-begin"].waitForExistence(timeout: 5))
            capture("Survey · Kickstart overview · \(appearance)", in: app)
            app.buttons["daily-review-begin"].tap()
            let keep = app.buttons["daily-review-keep-01ARZ3NDEKTSV4RRFFQ69G5FAW"]
            XCTAssertTrue(keep.waitForExistence(timeout: 5))
            capture("Survey · Review decision · \(appearance)", in: app)
            keep.tap()
            XCTAssertTrue(app.buttons["daily-review-keep-01ARZ3NDEKTSV4RRFFQ69G5FAV"].waitForExistence(timeout: 5))
            app.buttons["Close"].tap()

            app.buttons["filters-open"].tap()
            XCTAssertTrue(app.buttons["filter-add"].waitForExistence(timeout: 5))
            capture("Survey · Filter library · \(appearance)", in: app)
            app.buttons["filters-done"].tap()

            app.buttons["task-add"].tap()
            let name = app.textFields["task-editor-name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            capture("Survey · New todo · \(appearance)", in: app)
            name.tap()
            name.typeText("Plan a calm start to the week tomorrow")
            XCTAssertTrue(app.buttons["task-editor-save"].isEnabled)
            XCTAssertTrue(app.buttons["task-editor-projects"].isHittable)
            XCTAssertTrue(app.buttons["task-editor-save-another"].isHittable)
            capture("Survey · Capture with keyboard · \(appearance)", in: app)
            name.typeText(" #")
            let suggestion = app.buttons["task-editor-name-project-suggestion-work"]
            XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
            capture("Survey · Project suggestions · \(appearance)", in: app)
            suggestion.tap()
            app.saveAndAddAnotherTodo()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "task-editor-saved-confirmation")
                .firstMatch.waitForExistence(timeout: 8))
            XCTAssertEqual(app.buttons["task-editor-projects"].value as? String, "work")
            XCTAssertFalse(app.buttons["task-editor-save"].isEnabled)
            app.buttons["Cancel"].tap()

            app.buttons["task-add"].press(forDuration: 1.2)
            app.buttons["task-add-menu-bulk"].tap()
            let bulk = app.textViews["task-bulk-text"]
            XCTAssertTrue(bulk.waitForExistence(timeout: 5))
            capture("Survey · Bulk capture · \(appearance)", in: app)
            app.buttons["Cancel"].tap()
            app.terminate()
        }
    }

    @MainActor
    func testWorkspaceAndNavigationAtAccessibilityTextSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-light",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        defer { app.terminate() }
        let add = app.buttons["task-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        waitForTodos(in: app)
        XCTAssertTrue(add.isHittable, "Capture must remain reachable with accessibility text sizes")
        let firstTodo = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "task-row-")
        ).firstMatch
        XCTAssertTrue(firstTodo.isHittable, "Sync information must leave room to interact with todos")
        capture("Survey · Today · accessibility text", in: app)
        app.buttons["sync-details-toggle"].tap()
        XCTAssertTrue(app.buttons["sync-refresh"].waitForExistence(timeout: 5))
        capture("Survey · Sync details · accessibility text", in: app)
        app.buttons["sync-details-toggle"].tap()

        app.buttons["project-sidebar-toggle"].tap()
        let upcoming = app.buttons["upcoming-open"]
        XCTAssertTrue(upcoming.waitForExistence(timeout: 5))
        XCTAssertTrue(upcoming.isHittable, "Navigation must not be crowded out by utility controls")
        capture("Survey · Workspace navigation · accessibility text", in: app)
        app.buttons["project-sidebar-close"].tap()

        add.tap()
        XCTAssertTrue(app.textFields["task-editor-name"].waitForExistence(timeout: 5))
        capture("Survey · New todo · accessibility text", in: app)
    }

    @MainActor
    private func waitForTodos(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "task-row-")
        ).firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
