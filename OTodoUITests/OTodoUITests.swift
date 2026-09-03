import Foundation
import XCTest

final class OTodoUITests: XCTestCase {
    @MainActor
    func testAddAndEditTodo() {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launch()

        let taskList = app.descendants(matching: .any)
            .matching(identifier: "task-list")
            .firstMatch
        guard require(
            taskList,
            in: app,
            description: "the seeded task list"
        ) else { return }

        let seededTask = taskRow(named: "Seed todo", state: "Pending", in: app)
        guard require(
            seededTask,
            in: app,
            description: "the seeded Pending todo"
        ) else { return }

        let addButton = app.buttons["task-add"]
        guard require(
            addButton,
            in: app,
            description: "the Add Todo button"
        ) else { return }
        addButton.tap()

        let editor = app.descendants(matching: .any)
            .matching(identifier: "task-editor")
            .firstMatch
        guard require(
            editor,
            in: app,
            description: "the new todo editor"
        ) else { return }

        let nameField = app.textFields["task-editor-name"]
        guard require(
            nameField,
            in: app,
            description: "the todo name field"
        ) else { return }

        let originalName = "UI smoke todo"
        nameField.tap()
        nameField.typeText(originalName)

        let saveButton = app.buttons["task-editor-save"]
        guard require(
            saveButton,
            in: app,
            description: "the editor Save button"
        ) else { return }
        XCTAssertTrue(saveButton.isEnabled, "Save should be enabled for a valid todo name")
        saveButton.tap()

        let createdTask = taskRow(named: originalName, state: "Pending", in: app)
        guard require(
            createdTask,
            in: app,
            description: "the newly created Pending todo"
        ) else { return }

        let pendingStatus = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "waiting to sync")
        ).firstMatch
        guard require(
            pendingStatus,
            in: app,
            description: "the pending sync status after the local save"
        ) else { return }

        createdTask.tap()

        guard require(
            editor,
            in: app,
            description: "the editor for the created todo"
        ) else { return }
        guard require(
            nameField,
            in: app,
            description: "the persisted todo name field"
        ) else { return }
        XCTAssertEqual(
            nameField.value as? String,
            originalName,
            "Reopening the todo should load the durably saved name"
        )

        let suffix = " updated"
        nameField.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        nameField.typeText(suffix)

        guard require(
            saveButton,
            in: app,
            description: "the Save button while editing"
        ) else { return }
        XCTAssertTrue(saveButton.isEnabled, "Save should remain enabled after changing the name")
        saveButton.tap()

        let editedTask = taskRow(named: originalName + suffix, state: "Pending", in: app)
        _ = require(
            editedTask,
            in: app,
            description: "the todo with its edited name"
        )
    }

    @MainActor
    private func taskRow(
        named name: String,
        state: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                name,
                "State: \(state)"
            )
        ).firstMatch
    }

    @MainActor
    @discardableResult
    private func require(
        _ element: XCUIElement,
        in app: XCUIApplication,
        description: String,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Missing \(description)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Timed out waiting for \(description)", file: file, line: line)
            return false
        }
        return true
    }
}
