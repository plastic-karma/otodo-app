import Foundation
import XCTest

final class LocalOnlyModeUITests: XCTestCase {
    @MainActor
    func testLocalStorageWithoutOAuthPersistsTodoAcrossRelaunch() {
        continueAfterFailure = false

        let app = XCUIApplication()
        let resetArgument = "-ui-testing-reset-workspace"
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-onboarding",
            "-ui-testing-no-oauth",
            resetArgument,
        ]
        app.launch()

        let local = app.buttons["authentication.local"]
        XCTAssertTrue(local.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any)["authentication.githubUnavailable"].exists
        )
        local.tap()

        XCTAssertTrue(app.buttons["task-add"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sync-refresh"].isEnabled)
        XCTAssertEqual(app.buttons["sync-refresh"].label, "Refresh local workspace")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Local-only workspace without GitHub"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let active = app.buttons["task-filter-active"]
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        active.tap()
        app.buttons["task-add"].tap()

        let editor = app.descendants(matching: .any)
            .matching(identifier: "task-editor")
            .firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Local-only todo")
        app.buttons["task-editor-save"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        XCTAssertTrue(taskRow(named: "Local-only todo", in: app).waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments.removeAll { $0 == resetArgument }
        app.launch()

        XCTAssertTrue(app.buttons["task-add"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["authentication.local"].exists)
        app.buttons["task-filter-active"].tap()
        XCTAssertTrue(
            taskRow(named: "Local-only todo", in: app).waitForExistence(timeout: 5),
            "The local-only workspace must restore its todos without GitHub or a network connection"
        )
    }

    private func taskRow(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "\(name).")
        ).firstMatch
    }
}
