import Foundation
import XCTest

final class OTodoUITests: XCTestCase {
    @MainActor
    func testAddAndEditTodo() {
        continueAfterFailure = false

        let app = XCUIApplication()
        let resetWorkspaceArgument = "-ui-testing-reset-workspace"
        app.launchArguments.append(contentsOf: ["-ui-testing", resetWorkspaceArgument])
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

        guard requireEditorDismissed(
            editor,
            after: "creating the todo",
            in: app
        ) else { return }

        let pendingStatus = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "waiting to sync")
        ).firstMatch
        guard require(
            pendingStatus,
            in: app,
            description: "the pending sync status after the local save"
        ) else { return }

        guard let createdTask = requireTaskRow(
            named: originalName,
            state: "Pending",
            in: app,
            taskList: taskList,
            description: "the newly created Pending todo"
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

        guard requireEditorDismissed(
            editor,
            after: "editing the todo",
            in: app
        ) else { return }

        let editedName = originalName + suffix
        guard requireTaskRow(
            named: editedName,
            state: "Pending",
            in: app,
            taskList: taskList,
            description: "the edited Pending todo"
        ) != nil else { return }

        app.terminate()
        app.launchArguments = app.launchArguments.filter { $0 != resetWorkspaceArgument }
        app.launch()

        let relaunchedTaskList = app.descendants(matching: .any)
            .matching(identifier: "task-list")
            .firstMatch
        guard require(
            relaunchedTaskList,
            in: app,
            description: "the task list after relaunch"
        ) else { return }

        let relaunchedSeededTask = taskRow(named: "Seed todo", state: "Pending", in: app)
        guard require(
            relaunchedSeededTask,
            in: app,
            description: "the seeded Pending todo after relaunch"
        ) else { return }

        _ = requireTaskRow(
            named: editedName,
            state: "Pending",
            in: app,
            taskList: relaunchedTaskList,
            description: "the durably persisted edited Pending todo after relaunch"
        )
    }

    @MainActor
    private func requireTaskRow(
        named name: String,
        state: String,
        in app: XCUIApplication,
        taskList: XCUIElement,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement? {
        taskList.swipeUp()
        let row = taskRow(named: name, state: state, in: app)
        guard require(
            row,
            in: app,
            description: description,
            file: file,
            line: line
        ) else { return nil }
        return row
    }

    @MainActor
    private func requireEditorDismissed(
        _ editor: XCUIElement,
        after operation: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        guard editor.waitForNonExistence(timeout: timeout) else {
            let saveError = app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH %@", "Cannot save.")
            ).firstMatch
            let detail = saveError.exists
                ? " Visible save error: \(saveError.label)"
                : " No visible save error was exposed."
            attachDiagnostics(in: app, name: "Editor did not dismiss after \(operation)")
            XCTFail(
                "Editor did not dismiss after \(operation).\(detail)",
                file: file,
                line: line
            )
            return false
        }
        return true
    }

    @MainActor
    private func attachDiagnostics(in app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
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
            attachDiagnostics(in: app, name: "Missing \(description)")
            XCTFail("Timed out waiting for \(description)", file: file, line: line)
            return false
        }
        return true
    }
}
