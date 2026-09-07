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
            app.buttons["project-sidebar-close"].tap()

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
            capture("Survey · Capture with keyboard · \(appearance)", in: app)
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
        capture("Survey · Today · accessibility text", in: app)

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
