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

        guard selectFilter("Active", in: app) else { return }

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

        guard selectFilter("Active", in: app) else { return }

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
    func testDueDateUsesNativePicker() {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ui-testing", "-ui-testing-reset-workspace"])
        app.launch()

        let seededTask = taskRow(named: "Seed todo", state: "Pending", in: app)
        guard require(
            seededTask,
            in: app,
            description: "the seeded todo with a due date"
        ) else { return }
        seededTask.tap()

        let editor = app.descendants(matching: .any)
            .matching(identifier: "task-editor")
            .firstMatch
        guard require(
            editor,
            in: app,
            description: "the todo editor"
        ) else { return }

        guard require(
            app.switches["task-editor-due-date-toggle"],
            in: app,
            description: "the optional due-date control"
        ) else { return }
        guard require(
            app.datePickers["task-editor-due-date-picker"],
            in: app,
            description: "the native due-date picker"
        ) else { return }
        XCTAssertFalse(
            app.textFields["Due date"].exists,
            "Due dates should not use a text input"
        )
    }

    @MainActor
    func testTodayFilterIncludesOverdueAndIsDefault() {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ui-testing", "-ui-testing-reset-workspace"])
        app.launch()

        let taskList = app.descendants(matching: .any)
            .matching(identifier: "task-list")
            .firstMatch
        guard require(
            taskList,
            in: app,
            description: "the seeded task list"
        ) else { return }

        let filter = app.segmentedControls["task-filter"]
        guard require(
            filter,
            in: app,
            description: "the todo visibility filter"
        ) else { return }
        XCTAssertTrue(filter.buttons["Today"].isSelected, "Today should be selected by default")

        guard require(
            taskRow(named: "Overdue todo", state: "Pending", in: app),
            in: app,
            description: "the overdue todo in Today"
        ) else { return }
        guard require(
            taskRow(named: "Seed todo", state: "Pending", in: app),
            in: app,
            description: "the todo due today in Today"
        ) else { return }
        XCTAssertFalse(
            taskRow(named: "Future todo", state: "Pending", in: app).exists,
            "Today should hide future todos"
        )
        XCTAssertFalse(
            taskRow(named: "Undated todo", state: "Pending", in: app).exists,
            "Today should hide undated todos"
        )
        XCTAssertFalse(
            taskRow(named: "Completed overdue todo", state: "Done", in: app).exists,
            "Today should hide terminal todos"
        )

        guard selectFilter("Active", in: app) else { return }
        guard require(
            taskRow(named: "Future todo", state: "Pending", in: app),
            in: app,
            description: "the future todo in Active"
        ) else { return }
        guard require(
            taskRow(named: "Undated todo", state: "Pending", in: app),
            in: app,
            description: "the undated todo in Active"
        ) else { return }
        XCTAssertFalse(
            taskRow(named: "Completed overdue todo", state: "Done", in: app).exists,
            "Active should hide terminal todos"
        )

        guard selectFilter("All", in: app) else { return }
        _ = require(
            taskRow(named: "Completed overdue todo", state: "Done", in: app),
            in: app,
            description: "the completed overdue todo in All"
        )
    }

    @MainActor
    func testProjectSidebarFiltersEveryVisibility() {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ui-testing", "-ui-testing-reset-workspace"])
        app.launch()

        let sidebarButton = app.buttons["project-sidebar-toggle"]
        guard require(
            sidebarButton,
            in: app,
            description: "the project sidebar button"
        ) else { return }
        sidebarButton.tap()

        let sidebar = app.descendants(matching: .any)
            .matching(identifier: "project-sidebar")
            .firstMatch
        guard require(
            sidebar,
            in: app,
            description: "the project sidebar"
        ) else { return }

        let workProject = app.buttons["project-filter-work"]
        guard require(
            workProject,
            in: app,
            description: "the Work project filter"
        ) else { return }
        workProject.tap()
        XCTAssertTrue(
            sidebar.waitForNonExistence(timeout: 3),
            "Choosing a project should close the sidebar"
        )

        XCTAssertFalse(
            taskRow(named: "Seed todo", state: "Pending", in: app).exists,
            "Today should hide todos outside the selected project"
        )
        XCTAssertFalse(
            taskRow(named: "Overdue todo", state: "Pending", in: app).exists,
            "Today should hide overdue todos outside the selected project"
        )

        guard selectFilter("Active", in: app) else { return }
        guard require(
            taskRow(named: "Future todo", state: "Pending", in: app),
            in: app,
            description: "the active todo in Work"
        ) else { return }
        guard require(
            taskRow(named: "Undated todo", state: "Pending", in: app),
            in: app,
            description: "the undated todo in Work"
        ) else { return }
        XCTAssertFalse(
            taskRow(named: "Seed todo", state: "Pending", in: app).exists,
            "Active should remain scoped to Work"
        )

        guard selectFilter("All", in: app) else { return }
        XCTAssertFalse(
            taskRow(named: "Completed overdue todo", state: "Done", in: app).exists,
            "All should remain scoped to Work"
        )

        sidebarButton.tap()
        guard require(
            app.buttons["project-filter-all"],
            in: app,
            description: "the All Todos project filter"
        ) else { return }
        app.buttons["project-filter-all"].tap()

        guard selectFilter("Today", in: app) else { return }
        _ = require(
            taskRow(named: "Seed todo", state: "Pending", in: app),
            in: app,
            description: "the home todo after clearing the project filter"
        )
    }

    @MainActor
    func testSwipeActionsCompleteAndDeleteDurably() {
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

        let taskToComplete = taskRow(named: "Seed todo", state: "Pending", in: app)
        guard require(
            taskToComplete,
            in: app,
            description: "the todo to complete"
        ) else { return }
        taskToComplete.coordinate(
            withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)
        ).press(
            forDuration: 0.1,
            thenDragTo: taskToComplete.coordinate(
                withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)
            )
        )

        let doneButton = app.buttons["task-complete-01ARZ3NDEKTSV4RRFFQ69G5FAV"]
        guard require(
            doneButton,
            in: app,
            description: "the revealed Done swipe action"
        ) else { return }
        doneButton.tap()
        XCTAssertTrue(
            taskToComplete.waitForNonExistence(timeout: 8),
            "Completing a todo should remove it from Today"
        )

        let taskToDelete = taskRow(named: "Overdue todo", state: "Pending", in: app)
        guard require(
            taskToDelete,
            in: app,
            description: "the todo to delete"
        ) else { return }
        taskToDelete.coordinate(
            withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)
        ).press(
            forDuration: 0.1,
            thenDragTo: taskToDelete.coordinate(
                withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)
            )
        )

        let deleteButton = app.buttons["task-delete-01ARZ3NDEKTSV4RRFFQ69G5FAW"]
        guard require(
            deleteButton,
            in: app,
            description: "the revealed Delete swipe action"
        ) else { return }
        deleteButton.tap()
        XCTAssertTrue(
            taskToDelete.waitForNonExistence(timeout: 8),
            "Deleting a todo should remove it from the list"
        )

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
        guard selectFilter("All", in: app) else { return }
        guard require(
            taskRow(named: "Seed todo", state: "Done", in: app),
            in: app,
            description: "the durably completed todo after relaunch"
        ) else { return }
        XCTAssertFalse(
            taskRow(named: "Overdue todo", state: "Pending", in: app).exists,
            "The deleted todo should remain absent after relaunch"
        )
    }

    @MainActor
    private func selectFilter(
        _ name: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let button = app.segmentedControls["task-filter"].buttons[name]
        guard require(
            button,
            in: app,
            description: "the \(name) todo filter",
            file: file,
            line: line
        ) else { return false }
        button.tap()
        XCTAssertTrue(button.isSelected, "\(name) should be selected", file: file, line: line)
        return true
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
