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
        for _ in 0..<3 {
            if pendingStatus.exists {
                break
            }
            taskList.swipeUp()
        }
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
    func testNameDueDateIsHighlightedStrippedAndPersisted() {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ui-testing", "-ui-testing-reset-workspace"])
        app.launch()

        guard selectFilter("Active", in: app) else { return }

        let taskList = app.descendants(matching: .any)
            .matching(identifier: "task-list")
            .firstMatch
        guard require(
            taskList,
            in: app,
            description: "the seeded task list"
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
            description: "the highlighted todo name field"
        ) else { return }
        nameField.tap()
        nameField.typeText("Call mum Wed")

        let detection = app.descendants(matching: .any)
            .matching(identifier: "task-editor-detected-due-date")
            .firstMatch
        guard require(
            detection,
            in: app,
            description: "the detected due-date explanation"
        ) else { return }
        XCTAssertTrue(
            detection.label.localizedCaseInsensitiveContains("Wed"),
            "The detected phrase should remain identifiable while editing"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Detected abbreviated weekday in todo name"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let saveButton = app.buttons["task-editor-save"]
        guard require(
            saveButton,
            in: app,
            description: "the editor Save button"
        ) else { return }
        XCTAssertTrue(saveButton.isEnabled, "A name plus detected due date should be valid")
        saveButton.tap()
        guard requireEditorDismissed(
            editor,
            after: "creating a todo with a due date in its name",
            in: app
        ) else { return }

        guard let savedTask = requireTaskRow(
            named: "Call mum",
            state: "Pending",
            in: app,
            taskList: taskList,
            description: "the todo with its detected due date"
        ) else { return }

        savedTask.tap()
        guard require(
            editor,
            in: app,
            description: "the editor for the detected-date todo"
        ) else { return }
        XCTAssertEqual(
            nameField.value as? String,
            "Call mum",
            "Reopening the todo should load the stripped name"
        )
        XCTAssertEqual(
            app.switches["task-editor-due-date-toggle"].value as? String,
            "1",
            "Reopening the todo should load the detected due date"
        )
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testHomeScreenQuickActionOpensNewTodoEditor() {
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
            description: "the seeded task list before using the Home Screen shortcut"
        ) else { return }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()

        let appIcon = springboard.icons["OTodo"]
        guard require(
            appIcon,
            in: springboard,
            description: "the OTodo Home Screen icon"
        ) else { return }
        appIcon.press(forDuration: 1.2)

        let newTodoAction = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "New Todo"))
            .firstMatch
        guard require(
            newTodoAction,
            in: springboard,
            description: "the New Todo Home Screen quick action"
        ) else { return }

        let menuScreenshot = XCTAttachment(screenshot: springboard.screenshot())
        menuScreenshot.name = "New Todo Home Screen quick action"
        menuScreenshot.lifetime = .keepAlways
        add(menuScreenshot)

        newTodoAction.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let editor = app.descendants(matching: .any)
            .matching(identifier: "task-editor")
            .firstMatch
        guard require(
            editor,
            in: app,
            description: "the todo editor opened by the Home Screen quick action"
        ) else { return }
        XCTAssertTrue(
            app.textFields["task-editor-name"].exists,
            "The quick action should open a blank task creation editor"
        )
    }

    @MainActor
    func testTodayWidgetRendersInWidgetGallery() {
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
            description: "the seeded task list before opening the widget gallery"
        ) else { return }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()

        let appIcon = springboard.icons["OTodo"]
        guard require(
            appIcon,
            in: springboard,
            description: "the OTodo Home Screen icon"
        ) else { return }
        appIcon.press(forDuration: 1.2)

        let editHomeScreen = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Edit Home Screen"))
            .firstMatch
        guard require(
            editHomeScreen,
            in: springboard,
            description: "the Edit Home Screen menu action"
        ) else { return }
        editHomeScreen.tap()

        let addWidget = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Add Widget"))
            .firstMatch
        if !addWidget.waitForExistence(timeout: 2) {
            let editButton = springboard.buttons.matching(
                NSPredicate(format: "label ==[c] %@", "Edit")
            ).firstMatch
            guard require(
                editButton,
                in: springboard,
                description: "the Home Screen Edit button"
            ) else { return }
            editButton.tap()
        }
        guard require(
            addWidget,
            in: springboard,
            description: "the Home Screen Add Widget action"
        ) else { return }
        addWidget.tap()

        let searchField = springboard.searchFields.firstMatch
        guard require(
            searchField,
            in: springboard,
            description: "the widget gallery search field"
        ) else { return }
        searchField.tap()
        searchField.typeText("OTodo")

        let widgetProvider = springboard.staticTexts["OTodo"].firstMatch
        guard require(
            widgetProvider,
            in: springboard,
            description: "the OTodo widget provider"
        ) else { return }
        widgetProvider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let addWidgetConfirmation = springboard.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Add Widget")
        ).firstMatch
        guard require(
            addWidgetConfirmation,
            in: springboard,
            description: "the Add Widget button on the OTodo widget preview"
        ) else { return }

        let widgetScreenshot = XCTAttachment(screenshot: springboard.screenshot())
        widgetScreenshot.name = "OTodo Today widget"
        widgetScreenshot.lifetime = .keepAlways
        add(widgetScreenshot)
    }

    @MainActor
    func testDueDateAndTimeControlsPersistExactTime() {
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

        editor.swipeUp()
        let timeToggle = app.switches["task-editor-due-time-toggle"]
        guard require(
            timeToggle,
            in: app,
            description: "the optional due-time control"
        ) else { return }
        timeToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(
            timeToggle.value as? String,
            "1",
            "Enabling exact time should update the due-time control"
        )
        editor.swipeUp()

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Todo due time editor"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["task-editor-save"].tap()
        guard requireEditorDismissed(
            editor,
            after: "adding an exact due time",
            in: app
        ) else { return }

        let timedTask = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "Seed todo",
                "at 12:00"
            )
        ).firstMatch
        _ = require(
            timedTask,
            in: app,
            description: "the todo with its exact due time"
        )
    }

    @MainActor
    func testRelativeDueDateCanBeAppliedDuringCreation() {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ui-testing", "-ui-testing-reset-workspace"])
        app.launch()

        guard selectFilter("Active", in: app) else { return }

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

        let taskName = "Relative due todo"
        let nameField = app.textFields["task-editor-name"]
        guard require(
            nameField,
            in: app,
            description: "the todo name field"
        ) else { return }
        nameField.tap()
        nameField.typeText(taskName)

        let relativeField = app.textFields["task-editor-relative-due-date"]
        guard require(
            relativeField,
            in: app,
            description: "the relative due-date field"
        ) else { return }
        relativeField.tap()
        for character in "in 6 hours" {
            relativeField.typeText(String(character))
        }
        XCTAssertEqual(
            relativeField.value as? String,
            "in 6 hours",
            "Interactive typing should preserve every relative due-date character"
        )
        let applyButton = app.buttons["task-editor-relative-due-apply"]
        guard require(
            applyButton,
            in: app,
            description: "the relative due-date Apply button"
        ) else { return }
        XCTAssertTrue(applyButton.isEnabled, "A valid relative due date should be applicable")
        applyButton.tap()

        XCTAssertEqual(
            app.switches["task-editor-due-date-toggle"].value as? String,
            "1",
            "Applying a relative due date should set a calendar date"
        )
        editor.swipeUp()
        XCTAssertEqual(
            app.switches["task-editor-due-time-toggle"].value as? String,
            "1",
            "Applying a relative due date should preserve hour-and-minute precision"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Relative due date creation"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["task-editor-save"].tap()
        guard requireEditorDismissed(
            editor,
            after: "creating a todo with a relative due date",
            in: app
        ) else { return }

        let relativeTask = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                taskName,
                " at "
            )
        ).firstMatch
        _ = require(
            relativeTask,
            in: app,
            description: "the todo with its calculated exact due time"
        )
    }

    @MainActor
    func testContextMenuCompletesAndDeletesTodoDurably() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let resetWorkspaceArgument = "-ui-testing-reset-workspace"
        app.launchArguments.append(contentsOf: ["-ui-testing", resetWorkspaceArgument])
        app.launch()

        let pending = taskRow(named: "Seed todo", state: "Pending", in: app)
        guard require(pending, in: app, description: "the open todo for context actions") else { return }
        pending.press(forDuration: 1.2)
        let complete = app.buttons["task-context-complete-01ARZ3NDEKTSV4RRFFQ69G5FAV"]
        let reschedule = app.buttons["task-context-reschedule-01ARZ3NDEKTSV4RRFFQ69G5FAV"]
        let delete = app.buttons["task-context-delete-01ARZ3NDEKTSV4RRFFQ69G5FAV"]
        guard require(complete, in: app, description: "Done in the long-press menu"),
              require(reschedule, in: app, description: "Reschedule in the long-press menu"),
              require(delete, in: app, description: "Delete in the long-press menu")
        else { return }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Todo long-press menu with Done Reschedule and Delete"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        complete.tap()
        XCTAssertTrue(pending.waitForNonExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch.exists)

        app.terminate()
        app.launchArguments.removeAll { $0 == resetWorkspaceArgument }
        app.launch()
        guard selectFilter("All", in: app) else { return }
        let completed = taskRow(named: "Seed todo", state: "Done", in: app)
        guard require(completed, in: app, description: "the durably completed todo") else { return }
        completed.press(forDuration: 1.2)
        guard require(delete, in: app, description: "Delete for an already completed todo") else { return }
        XCTAssertFalse(complete.exists, "Done should not reopen an already terminal todo")
        delete.tap()
        XCTAssertTrue(completed.waitForNonExistence(timeout: 8))

        app.terminate()
        app.launch()
        guard selectFilter("All", in: app) else { return }
        guard require(
            taskRow(named: "Completed overdue todo", state: "Done", in: app),
            in: app,
            description: "an unrelated completed todo retained after relaunch"
        ) else { return }
        XCTAssertFalse(app.buttons["task-row-01ARZ3NDEKTSV4RRFFQ69G5FAV"].exists)
    }

    @MainActor
    func testTaskCanBeRescheduledFromContextMenu() {
        continueAfterFailure = false

        let app = XCUIApplication()
        let resetWorkspaceArgument = "-ui-testing-reset-workspace"
        app.launchArguments.append(contentsOf: ["-ui-testing", resetWorkspaceArgument])
        app.launch()

        guard selectFilter("Active", in: app) else { return }

        let taskList = app.descendants(matching: .any)
            .matching(identifier: "task-list")
            .firstMatch
        guard require(
            taskList,
            in: app,
            description: "the seeded task list"
        ) else { return }

        let task = taskRow(named: "Seed todo", state: "Pending", in: app)
        guard require(
            task,
            in: app,
            description: "the todo to reschedule"
        ) else { return }
        let originalLabel = task.label
        task.press(forDuration: 1.2)

        let rescheduleAction = app.buttons[
            "task-context-reschedule-01ARZ3NDEKTSV4RRFFQ69G5FAV"
        ]
        guard require(
            rescheduleAction,
            in: app,
            description: "the Reschedule context-menu action"
        ) else { return }
        rescheduleAction.tap()

        let rescheduler = app.descendants(matching: .any)
            .matching(identifier: "task-reschedule")
            .firstMatch
        guard require(
            rescheduler,
            in: app,
            description: "the reschedule sheet"
        ) else { return }

        let relativeField = app.textFields["task-reschedule-relative-due-date"]
        guard require(
            relativeField,
            in: app,
            description: "the reschedule relative-date field"
        ) else { return }
        relativeField.tap()
        relativeField.typeText("in 2 days")

        let applyButton = app.buttons["task-reschedule-relative-due-apply"]
        guard require(
            applyButton,
            in: app,
            description: "the reschedule Apply button"
        ) else { return }
        XCTAssertTrue(applyButton.isEnabled, "A valid relative schedule should be applicable")
        applyButton.tap()
        XCTAssertTrue(
            app.keyboards.element.waitForNonExistence(timeout: 3),
            "Applying a relative schedule should dismiss the keyboard"
        )

        rescheduler.swipeUp()
        guard require(
            app.datePickers["task-reschedule-date-picker"],
            in: app,
            description: "the reschedule calendar picker"
        ) else { return }
        let timeToggle = app.switches["task-reschedule-time-toggle"]
        guard require(
            timeToggle,
            in: app,
            description: "the reschedule exact-time control"
        ) else { return }
        XCTAssertEqual(
            timeToggle.value as? String,
            "1",
            "A relative schedule should preserve exact minute precision"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Todo reschedule sheet"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["task-reschedule-save"].tap()
        guard requireEditorDismissed(
            rescheduler,
            after: "rescheduling the todo",
            in: app
        ) else { return }

        guard let rescheduledTask = requireTaskRow(
            named: "Seed todo",
            state: "Pending",
            in: app,
            taskList: taskList,
            description: "the rescheduled todo"
        ) else { return }
        let rescheduledLabel = rescheduledTask.label
        XCTAssertNotEqual(
            rescheduledLabel,
            originalLabel,
            "Rescheduling should replace the prior due date"
        )
        XCTAssertTrue(
            rescheduledLabel.contains(" at "),
            "A relative reschedule should persist its exact time"
        )

        app.terminate()
        app.launchArguments = app.launchArguments.filter { $0 != resetWorkspaceArgument }
        app.launch()

        guard selectFilter("Active", in: app) else { return }
        let relaunchedTaskList = app.descendants(matching: .any)
            .matching(identifier: "task-list")
            .firstMatch
        guard require(
            relaunchedTaskList,
            in: app,
            description: "the task list after relaunch"
        ) else { return }
        guard let persistedTask = requireTaskRow(
            named: "Seed todo",
            state: "Pending",
            in: app,
            taskList: relaunchedTaskList,
            description: "the durably rescheduled todo"
        ) else { return }
        XCTAssertEqual(
            persistedTask.label,
            rescheduledLabel,
            "The rescheduled due date and time should survive relaunch"
        )
    }

    @MainActor
    func testLeadingSwipeOffersCompleteAndReschedule() {
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

        let task = taskRow(named: "Seed todo", state: "Pending", in: app)
        guard require(
            task,
            in: app,
            description: "the todo with leading swipe actions"
        ) else { return }
        task.coordinate(
            withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)
        ).press(
            forDuration: 0.1,
            thenDragTo: task.coordinate(
                withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)
            )
        )

        guard require(
            app.buttons["task-complete-01ARZ3NDEKTSV4RRFFQ69G5FAV"],
            in: app,
            description: "the revealed Done swipe action"
        ) else { return }
        let rescheduleAction = app.buttons[
            "task-reschedule-01ARZ3NDEKTSV4RRFFQ69G5FAV"
        ]
        guard require(
            rescheduleAction,
            in: app,
            description: "the revealed Reschedule swipe action"
        ) else { return }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Right swipe task actions"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        rescheduleAction.tap()
        let rescheduler = app.descendants(matching: .any)
            .matching(identifier: "task-reschedule")
            .firstMatch
        guard require(
            rescheduler,
            in: app,
            description: "the reschedule sheet from the leading swipe"
        ) else { return }

        app.buttons["Cancel"].tap()
        XCTAssertTrue(
            rescheduler.waitForNonExistence(timeout: 3),
            "Cancel should dismiss the reschedule sheet"
        )
    }

    @MainActor
    func testFilteredCreationPersistsProjectsAndTagsForSingleAndBulkTodos() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace"]
        app.launch()

        let openFilters = app.buttons["filters-open"]
        guard require(openFilters, in: app, description: "the filter library entry") else { return }
        openFilters.tap()
        app.buttons["filter-add"].tap()
        let filterName = app.textFields["filter-editor-name"]
        guard require(filterName, in: app, description: "the new filter name") else { return }
        filterName.tap()
        filterName.typeText("Scoped creation")
        let query = app.descendants(matching: .any)
            .matching(identifier: "filter-editor-query").firstMatch
        query.tap()
        query.typeText("active AND project:work AND tag:focus AND NOT tag:waiting")
        app.buttons["filter-editor-save"].tap()
        let filterEditor = app.descendants(matching: .any)
            .matching(identifier: "filter-editor").firstMatch
        guard requireEditorDismissed(filterEditor, after: "saving the creation filter", in: app) else { return }
        let saved = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "filter-open-", "Scoped creation")
        ).firstMatch
        guard require(saved, in: app, description: "the saved creation filter") else { return }
        saved.tap()
        let library = app.descendants(matching: .any)
            .matching(identifier: "filter-library").firstMatch
        XCTAssertTrue(library.waitForNonExistence(timeout: 8))

        app.buttons["project-sidebar-toggle"].tap()
        app.buttons["project-filter-home"].tap()
        let addButton = app.buttons["task-add"]
        addButton.tap()
        let name = app.textFields["task-editor-name"]
        guard require(name, in: app, description: "the context-prefilled todo editor") else { return }
        XCTAssertEqual(app.buttons["home project"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["work project"].value as? String, "Selected")
        let editor = app.descendants(matching: .any)
            .matching(identifier: "task-editor").firstMatch
        let tags = app.textFields["task-editor-tags"]
        XCTAssertEqual(tags.value as? String, "focus", "Excluded tags must not be inherited")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "New todo inherits the filter and sidebar project"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        name.tap()
        name.typeText("Scoped single")
        app.buttons["task-editor-save"].tap()
        guard requireEditorDismissed(editor, after: "creating a context-prefilled todo", in: app) else { return }
        guard require(
            taskRow(named: "Scoped single", state: "Pending", in: app),
            in: app, description: "the created todo in the original filtered project view"
        ) else { return }

        addButton.press(forDuration: 1.2)
        app.buttons["task-add-menu-bulk"].tap()
        let bulkText = app.textViews["task-bulk-text"]
        guard require(bulkText, in: app, description: "the scoped bulk editor") else { return }
        bulkText.tap()
        bulkText.typeText("Scoped batch one\nScoped batch two")
        app.buttons["task-bulk-save"].tap()
        let bulkEditor = app.descendants(matching: .any)
            .matching(identifier: "task-bulk-editor").firstMatch
        guard requireEditorDismissed(bulkEditor, after: "creating a context-prefilled batch", in: app) else { return }

        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        guard require(openFilters, in: app, description: "the library after relaunch") else { return }
        openFilters.tap()
        guard require(saved, in: app, description: "the persisted creation filter") else { return }
        saved.tap()
        XCTAssertTrue(library.waitForNonExistence(timeout: 8))
        app.buttons["project-sidebar-toggle"].tap()
        app.buttons["project-filter-home"].tap()
        let taskList = app.descendants(matching: .any)
            .matching(identifier: "task-list").firstMatch
        for taskName in ["Scoped single", "Scoped batch one", "Scoped batch two"] {
            guard let row = requireTaskRow(
                named: taskName, state: "Pending", in: app, taskList: taskList,
                description: "the persisted \(taskName) with both projects and the filter tag"
            ) else { return }
            row.tap()
            guard require(name, in: app, description: "the saved labels on \(taskName)") else { return }
            XCTAssertEqual(app.buttons["home project"].value as? String, "Selected")
            XCTAssertEqual(app.buttons["work project"].value as? String, "Selected")
            XCTAssertEqual(tags.value as? String, "focus")
            app.buttons["Cancel"].tap()
            guard requireEditorDismissed(editor, after: "inspecting \(taskName)", in: app) else { return }
        }
    }

    @MainActor
    func testSavedFiltersPersistEditsAndHomeStars() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace"]
        app.launch()

        let openFilters = app.buttons["filters-open"]
        guard require(openFilters, in: app, description: "the filter library entry") else { return }
        openFilters.tap()
        let addFilterButton = app.buttons["filter-add"]
        guard require(addFilterButton, in: app, description: "the New Filter button") else { return }
        addFilterButton.tap()
        let name = app.textFields["filter-editor-name"]
        guard require(name, in: app, description: "the filter name field") else { return }
        name.tap()
        name.typeText("Work invoices")
        let query = app.descendants(matching: .any)
            .matching(identifier: "filter-editor-query").firstMatch
        guard require(query, in: app, description: "the text query editor") else { return }
        query.tap()
        query.typeText("next-seven-days AND")
        let save = app.buttons["filter-editor-save"]
        XCTAssertFalse(save.isEnabled, "An unfinished boolean expression must not be saved")
        query.typeText(" project:wo")
        let projectCompletion = app.buttons["filter-completion-project-work"]
        guard require(projectCompletion, in: app, description: "the matching Work project completion") else { return }
        let completionScreenshot = XCTAttachment(screenshot: app.screenshot())
        completionScreenshot.name = "Project autocomplete in the filter query"
        completionScreenshot.lifetime = .keepAlways
        add(completionScreenshot)
        projectCompletion.tap()
        query.typeText(" AND tag:fo")
        let tagCompletion = app.buttons["filter-completion-tag-focus"]
        guard require(tagCompletion, in: app, description: "the matching focus tag completion") else { return }
        tagCompletion.tap()
        query.typeText(" AND name:/future/i AND description:/invoice/i")
        app.buttons["filter-editor-star"].tap()
        XCTAssertTrue(save.isEnabled, "A complete query can be saved")
        let editorScreenshot = XCTAttachment(screenshot: app.screenshot())
        editorScreenshot.name = "Saved filter text editor"
        editorScreenshot.lifetime = .keepAlways
        add(editorScreenshot)
        save.tap()
        let editor = app.descendants(matching: .any)
            .matching(identifier: "filter-editor").firstMatch
        guard requireEditorDismissed(editor, after: "saving a filter", in: app) else { return }

        let saved = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "filter-open-", "Work invoices")
        ).firstMatch
        guard require(saved, in: app, description: "the saved custom filter") else { return }
        let id = String(saved.identifier.dropFirst("filter-open-".count))
        saved.tap()
        let library = app.descendants(matching: .any)
            .matching(identifier: "filter-library").firstMatch
        XCTAssertTrue(library.waitForNonExistence(timeout: 8))
        let future = taskRow(named: "Future todo", state: "Pending", in: app)
        guard require(future, in: app, description: "the matching invoice todo") else { return }
        XCTAssertFalse(taskRow(named: "Seed todo", state: "Pending", in: app).exists)
        XCTAssertFalse(taskRow(named: "Undated todo", state: "Pending", in: app).exists)

        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        let favorite = app.buttons["task-filter-\(id)"]
        guard require(favorite, in: app, description: "the saved star on Home after relaunch") else { return }
        app.scrollViews["task-filters"].swipeLeft()
        favorite.tap()
        guard require(future, in: app, description: "the persisted query result") else { return }
        let homeScreenshot = XCTAttachment(screenshot: app.screenshot())
        homeScreenshot.name = "Starred custom filter on Home"
        homeScreenshot.lifetime = .keepAlways
        add(homeScreenshot)

        openFilters.tap()
        guard require(saved, in: app, description: "the filter to edit") else { return }
        saved.press(forDuration: 1.2)
        let edit = app.buttons["filter-edit-\(id)"]
        guard require(edit, in: app, description: "the Edit Filter action") else { return }
        edit.tap()
        guard require(query, in: app, description: "the saved query for editing") else { return }
        query.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        query.typeText(" AND NOT name:/future/i")
        save.tap()
        guard requireEditorDismissed(editor, after: "editing a filter", in: app) else { return }
        saved.tap()
        XCTAssertTrue(library.waitForNonExistence(timeout: 8))
        XCTAssertTrue(future.waitForNonExistence(timeout: 8), "Editing must invalidate the compiled query")
        guard require(
            app.buttons["Add a Todo"], in: app, description: "the empty filtered view's add action"
        ) else { return }
        let emptyScreenshot = XCTAttachment(screenshot: app.screenshot())
        emptyScreenshot.name = "Encouraging empty filtered view"
        emptyScreenshot.lifetime = .keepAlways
        add(emptyScreenshot)

        openFilters.tap()
        let star = app.buttons["filter-star-\(id)"]
        guard require(star, in: app, description: "the saved filter's Home star") else { return }
        star.tap()
        let unstarred = expectation(
            for: NSPredicate(format: "value == %@", "Off"),
            evaluatedWith: star
        )
        wait(for: [unstarred], timeout: 8)
        app.buttons["filters-done"].tap()
        XCTAssertTrue(favorite.waitForNonExistence(timeout: 8))
        app.terminate()
        app.launch()
        XCTAssertFalse(favorite.exists, "Removing a Home star must persist")
        openFilters.tap()
        guard require(saved, in: app, description: "the unstarred filter retained in the library") else { return }
        saved.press(forDuration: 1.2)
        let delete = app.buttons["filter-delete-\(id)"]
        guard require(delete, in: app, description: "the Delete Filter action") else { return }
        delete.tap()
        XCTAssertTrue(saved.waitForNonExistence(timeout: 8))
        app.terminate()
        app.launch()
        openFilters.tap()
        guard require(addFilterButton, in: app, description: "the library after deleting a filter") else { return }
        XCTAssertFalse(saved.exists, "Deleted filters must not return after relaunch")
    }

    @MainActor
    func testTodayFilterIncludesOverdueAndIsDefault() {
        continueAfterFailure = false
        verifyTodayFilters(appearance: "light")
        verifyTodayFilters(appearance: "dark")
    }

    @MainActor
    private func verifyTodayFilters(appearance: String) {

        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-\(appearance)",
        ])
        app.launch()
        defer { app.terminate() }

        let taskList = app.descendants(matching: .any)
            .matching(identifier: "task-list")
            .firstMatch
        guard require(
            taskList,
            in: app,
            description: "the seeded task list"
        ) else { return }

        let filter = app.buttons["task-filter-today"]
        guard require(
            filter,
            in: app,
            description: "the todo visibility filter"
        ) else { return }
        XCTAssertTrue(filter.isSelected, "Today should be selected by default")

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

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Today workspace - \(appearance)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

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

        app.buttons["project-sidebar-toggle"].tap()
        guard require(
            app.buttons["project-filter-work"],
            in: app,
            description: "the Work project"
        ) else { return }
        let sidebarScreenshot = XCTAttachment(screenshot: app.screenshot())
        sidebarScreenshot.name = "Projects - \(appearance)"
        sidebarScreenshot.lifetime = .keepAlways
        add(sidebarScreenshot)
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
    func testTagInputAutocompletesExistingTags() {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ui-testing", "-ui-testing-reset-workspace"])
        app.launch()

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

        let tagsField = app.textFields["task-editor-tags"]
        guard require(
            tagsField,
            in: app,
            description: "the tag input"
        ) else { return }
        tagsField.tap()
        tagsField.typeText("fo")

        let suggestion = app.buttons["tag-suggestion-focus"]
        guard require(
            suggestion,
            in: app,
            description: "the matching Focus tag suggestion"
        ) else { return }
        suggestion.tap()

        XCTAssertEqual(
            tagsField.value as? String,
            "focus, ",
            "Choosing a suggestion should complete the current tag"
        )
    }

    @MainActor
    func testCreateProjectPersistsAfterRelaunch() {
        continueAfterFailure = false

        let app = XCUIApplication()
        let resetWorkspaceArgument = "-ui-testing-reset-workspace"
        app.launchArguments.append(contentsOf: ["-ui-testing", resetWorkspaceArgument])
        app.launch()

        let sidebarButton = app.buttons["project-sidebar-toggle"]
        let addButton = app.buttons["task-add"]
        guard require(
            addButton,
            in: app,
            description: "the quick-add button"
        ) else { return }
        addButton.press(forDuration: 1.2)

        let addProjectButton = app.buttons["project-add"]
        guard require(
            addProjectButton,
            in: app,
            description: "the New Project button"
        ) else { return }
        XCTAssertFalse(
            app.textFields["task-editor-name"].exists,
            "Holding plus must open the menu, not create a todo"
        )
        let menuScreenshot = XCTAttachment(screenshot: app.screenshot())
        menuScreenshot.name = "Quick-add todo and project menu"
        menuScreenshot.lifetime = .keepAlways
        add(menuScreenshot)
        addProjectButton.tap()

        let editor = app.descendants(matching: .any)
            .matching(identifier: "project-editor")
            .firstMatch
        guard require(
            editor,
            in: app,
            description: "the project editor"
        ) else { return }

        let nameField = app.textFields["project-editor-name"]
        guard require(
            nameField,
            in: app,
            description: "the project name field"
        ) else { return }
        nameField.tap()
        nameField.typeText("Side Project")

        let slugLabel = app.staticTexts["project-editor-slug"]
        guard require(
            slugLabel,
            in: app,
            description: "the generated project slug"
        ) else { return }
        XCTAssertTrue(
            slugLabel.label.hasSuffix("side-project"),
            "The project name should generate the side-project slug"
        )

        let saveButton = app.buttons["project-editor-save"]
        guard require(
            saveButton,
            in: app,
            description: "the project Save button"
        ) else { return }
        XCTAssertTrue(saveButton.isEnabled, "A valid generated slug should enable Save")
        saveButton.tap()
        guard requireEditorDismissed(
            editor,
            after: "creating the project",
            in: app
        ) else { return }

        guard require(
            app.navigationBars["Side Project"],
            in: app,
            description: "the newly selected project"
        ) else { return }

        sidebarButton.tap()
        let createdProject = app.buttons["project-filter-side-project"]
        guard require(
            createdProject,
            in: app,
            description: "the new project in the sidebar"
        ) else { return }
        XCTAssertEqual(
            createdProject.value as? String,
            "Selected",
            "The new project should become the active filter"
        )

        app.terminate()
        app.launchArguments = app.launchArguments.filter { $0 != resetWorkspaceArgument }
        app.launch()

        let relaunchedSidebarButton = app.buttons["project-sidebar-toggle"]
        guard require(
            relaunchedSidebarButton,
            in: app,
            description: "the project sidebar button after relaunch"
        ) else { return }
        relaunchedSidebarButton.tap()
        _ = require(
            app.buttons["project-filter-side-project"],
            in: app,
            description: "the durably saved project after relaunch"
        )
    }

    @MainActor
    func testCircleCompletesAndReopensTodoDurablyWithoutOpeningEditor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let resetWorkspaceArgument = "-ui-testing-reset-workspace"
        app.launchArguments.append(contentsOf: ["-ui-testing", resetWorkspaceArgument])
        app.launch()

        let pending = taskRow(named: "Seed todo", state: "Pending", in: app)
        guard require(pending, in: app, description: "the open todo") else { return }
        let sidebar = app.descendants(matching: .any).matching(identifier: "project-sidebar").firstMatch
        guard requireProjectCounts([(nil, 4), ("home", 2), ("work", 2)], in: app) else { return }
        app.buttons["project-sidebar-close"].tap()
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 8), "Closing Projects must restore task interactions")
        let circle = app.buttons["task-toggle-completion-01ARZ3NDEKTSV4RRFFQ69G5FAV"]
        guard require(circle, in: app, description: "the todo completion circle") else { return }
        circle.tap()
        XCTAssertTrue(pending.waitForNonExistence(timeout: 8))
        let editor = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
        XCTAssertFalse(editor.exists, "Tapping the circle should not open the editor")

        app.terminate()
        app.launchArguments.removeAll { $0 == resetWorkspaceArgument }
        app.launch()
        guard selectFilter("All", in: app) else { return }
        guard require(
            taskRow(named: "Seed todo", state: "Done", in: app),
            in: app,
            description: "the completed todo persisted after relaunch"
        ) else { return }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Completed todo with tappable reopen circle"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        guard requireProjectCounts([(nil, 3), ("home", 1), ("work", 2)], in: app) else { return }
        let countsScreenshot = XCTAttachment(screenshot: app.screenshot())
        countsScreenshot.name = "Project badges exclude completed todos while All is selected"
        countsScreenshot.lifetime = .keepAlways
        add(countsScreenshot)
        app.buttons["project-sidebar-close"].tap()
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 8), "Closing Projects must restore task interactions")

        guard require(circle, in: app, description: "the completed todo circle") else { return }
        circle.tap()
        guard require(pending, in: app, description: "the reopened todo") else { return }
        XCTAssertFalse(editor.exists, "Reopening from the circle should not open the editor")

        app.terminate()
        app.launch()
        guard selectFilter("Today", in: app) else { return }
        guard require(pending, in: app, description: "the reopened todo persisted in Today") else { return }
        guard requireProjectCounts([(nil, 4), ("home", 2), ("work", 2)], in: app) else { return }
        app.buttons["project-sidebar-close"].tap()
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 8), "Closing Projects must restore task interactions")
        pending.tap()
        guard require(editor, in: app, description: "the editor opened by tapping the todo title") else { return }
        XCTAssertEqual(app.buttons["home project"].value as? String, "Selected")
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testSidebarChangelogShowsNewestCommitTimesOfflineAndPreservesScope() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ui-testing", "-ui-testing-reset-workspace"])
        app.launch()
        guard selectFilter("Active", in: app) else { return }
        let sidebarButton = app.buttons["project-sidebar-toggle"]
        sidebarButton.tap()
        let workProject = app.buttons["project-filter-work"]
        guard require(workProject, in: app, description: "the Work project scope") else { return }
        workProject.tap()
        guard require(
            taskRow(named: "Future todo", state: "Pending", in: app),
            in: app,
            description: "the active Work todo before opening the changelog"
        ) else { return }

        sidebarButton.tap()
        let openChangelog = app.buttons["changelog-open"]
        guard require(openChangelog, in: app, description: "the sidebar changelog action") else { return }
        openChangelog.tap()
        let changelog = app.descendants(matching: .any).matching(identifier: "changelog-list").firstMatch
        guard require(changelog, in: app, description: "the offline bundled changelog") else { return }
        let timestampQuery = app.staticTexts.matching(identifier: "changelog-timestamp")
        guard require(timestampQuery.firstMatch, in: app, description: "the loaded commit timestamps") else { return }
        let timestamps = timestampQuery
            .allElementsBoundByIndex
            .filter(\.isHittable)
            .sorted { $0.frame.minY < $1.frame.minY }
        guard timestamps.count >= 2 else {
            XCTFail("The changelog must show multiple commit timestamps to verify their visual order")
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withSpaceBetweenDateAndTime]
        let dates = try timestamps.map {
            try XCTUnwrap(formatter.date(from: $0.label), "The displayed commit timestamp must include seconds and timezone")
        }
        for (newer, older) in zip(dates, dates.dropFirst()) {
            XCTAssertGreaterThanOrEqual(newer, older, "Commit timestamps must be newest first on screen")
        }
        XCTAssertGreaterThan(dates[0], dates[dates.count - 1], "Distinct commits must retain their own timestamps")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Offline changelog with exact newest-first commit timestamps"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let closeChangelog = app.buttons["changelog-close"]
        guard require(closeChangelog, in: app, description: "the changelog Done action") else { return }
        closeChangelog.tap()
        XCTAssertTrue(changelog.waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.buttons["task-filter-active"].isSelected)
        guard require(
            taskRow(named: "Future todo", state: "Pending", in: app),
            in: app,
            description: "the unchanged Work scope after closing the changelog"
        ) else { return }
        XCTAssertFalse(taskRow(named: "Seed todo", state: "Pending", in: app).exists)
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
    func testDueReminderControlIsAvailable() {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ui-testing", "-ui-testing-reset-workspace"])
        app.launch()

        let sidebarButton = app.buttons["project-sidebar-toggle"]
        guard require(
            sidebarButton,
            in: app,
            description: "the Projects sidebar button"
        ) else { return }
        sidebarButton.tap()

        let reminderControl = app.buttons["notification-settings"]
        guard require(
            reminderControl,
            in: app,
            description: "the due reminder control"
        ) else { return }
        let supportedValues = ["Not configured", "On", "Off", "Permission required"]
        let accessibilityValue = reminderControl.value as? String
        XCTAssertTrue(
            supportedValues.contains(accessibilityValue ?? ""),
            "Reminder control should expose its current authorization state"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Due reminder control"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSyncStatusStaysPinnedWhileTodosScroll() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ui-testing", "-ui-testing-reset-workspace"])
        app.launch()
        guard selectFilter("Active", in: app) else { return }
        let addButton = app.buttons["task-add"]
        guard require(addButton, in: app, description: "the quick-add control") else { return }
        addButton.press(forDuration: 1.2)
        let bulkAction = app.buttons["task-add-menu-bulk"]
        guard require(bulkAction, in: app, description: "the Bulk Add action") else { return }
        bulkAction.tap()
        let input = app.textViews["task-bulk-text"]
        guard require(input, in: app, description: "the multiline todo input") else { return }
        input.tap()
        input.typeText((1...16).map { String(format: "Scrollable todo %02d", $0) }.joined(separator: "\n"))
        app.buttons["task-bulk-save"].tap()
        let bulkEditor = app.descendants(matching: .any).matching(identifier: "task-bulk-editor").firstMatch
        XCTAssertTrue(bulkEditor.waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 8))

        let taskList = app.descendants(matching: .any).matching(identifier: "task-list").firstMatch
        let status = app.descendants(matching: .any).matching(identifier: "sync-status").firstMatch
        guard require(status, in: app, description: "the pinned update information for a long list") else { return }
        let initialFrame = status.frame
        XCTAssertTrue(status.isHittable)
        XCTAssertGreaterThan(initialFrame.minY, app.frame.midY)
        XCTAssertLessThanOrEqual(initialFrame.maxY, app.frame.maxY)
        XCTAssertFalse(initialFrame.intersects(addButton.frame), "Update information must not overlap quick add")
        XCTAssertTrue(app.buttons["sync-refresh"].exists)

        let firstScrollable = taskRow(named: "Scrollable todo 01", state: "Pending", in: app)
        guard require(firstScrollable, in: app, description: "the first added todo before scrolling") else { return }
        let lastTodo = taskRow(named: "Undated todo", state: "Pending", in: app)
        for _ in 0..<4 where !lastTodo.isHittable {
            taskList.swipeUp()
        }
        XCTAssertTrue(lastTodo.isHittable, "The final todo must remain reachable above the pinned bar")
        XCTAssertFalse(firstScrollable.isHittable, "The todo list must actually scroll")
        XCTAssertTrue(status.isHittable)
        XCTAssertEqual(status.frame.minY, initialFrame.minY, accuracy: 1)
        XCTAssertEqual(status.frame.maxY, initialFrame.maxY, accuracy: 1)
        XCTAssertTrue(addButton.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Update information and quick add remain pinned after scrolling"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testBulkTextCreatesDatedAndUndatedTodosDurably() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let reset = "-ui-testing-reset-workspace"
        app.launchArguments = ["-ui-testing", reset]
        app.launch()
        guard selectFilter("Active", in: app) else { return }

        let addButton = app.buttons["task-add"]
        guard require(addButton, in: app, description: "the quick-add button") else { return }
        addButton.press(forDuration: 1.2)
        let bulkButton = app.buttons["task-add-menu-bulk"]
        guard require(bulkButton, in: app, description: "the Bulk Add action") else { return }
        bulkButton.tap()

        let bulkEditor = app.descendants(matching: .any)
            .matching(identifier: "task-bulk-editor").firstMatch
        let text = app.textViews["task-bulk-text"]
        guard require(text, in: app, description: "the multiline todo input") else { return }
        let create = app.buttons["task-bulk-save"]
        XCTAssertFalse(create.isEnabled, "An empty batch cannot be created")
        text.tap()
        text.typeText("Bulk milk tomorrow\n\nBulk rent Mon\nBulk undated")
        XCTAssertTrue(create.isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Multiline bulk todo creation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        create.tap()
        guard requireEditorDismissed(
            bulkEditor, after: "creating the bulk todos", in: app
        ) else { return }

        app.terminate()
        app.launchArguments.removeAll { $0 == reset }
        app.launch()
        guard selectFilter("Active", in: app) else { return }
        let taskList = app.descendants(matching: .any)
            .matching(identifier: "task-list").firstMatch
        let editor = app.descendants(matching: .any)
            .matching(identifier: "task-editor").firstMatch
        for (name, hasDate) in [
            ("Bulk milk", true), ("Bulk rent", true), ("Bulk undated", false),
        ] {
            guard let task = requireTaskRow(
                named: name, state: "Pending", in: app, taskList: taskList,
                description: "the persisted \(name) todo"
            ) else { return }
            task.tap()
            guard require(editor, in: app, description: "the persisted bulk todo editor") else { return }
            XCTAssertEqual(app.textFields["task-editor-name"].value as? String, name)
            XCTAssertEqual(
                app.switches["task-editor-due-date-toggle"].value as? String,
                hasDate ? "1" : "0",
                "Only dates parsed from each line should be saved"
            )
            app.buttons["Cancel"].tap()
        }
    }

    @MainActor
    func testCreateAnotherResetsScheduleAndKeepsProjectAndTags() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let reset = "-ui-testing-reset-workspace"
        app.launchArguments = ["-ui-testing", reset]
        app.launch()
        guard selectFilter("Active", in: app) else { return }
        app.buttons["task-add"].tap()

        let editor = app.descendants(matching: .any)
            .matching(identifier: "task-editor").firstMatch
        let name = app.textFields["task-editor-name"]
        guard require(name, in: app, description: "the new todo name") else { return }
        name.tap()
        name.typeText("Repeated first")
        app.buttons["work project"].tap()
        editor.swipeUp()
        let tags = app.textFields["task-editor-tags"]
        guard require(tags, in: app, description: "the shared tags input") else { return }
        tags.tap()
        tags.typeText("focus")
        editor.swipeUp()
        let relative = app.textFields["task-editor-relative-due-date"]
        guard require(relative, in: app, description: "the first todo's relative schedule") else { return }
        relative.tap()
        relative.typeText("in 6 hours")
        app.buttons["task-editor-relative-due-apply"].tap()
        let repeatPicker = app.buttons["task-editor-repeat"]
        for _ in 0..<6 {
            if repeatPicker.exists && repeatPicker.isHittable { break }
            editor.swipeUp()
        }
        guard require(repeatPicker, in: app, description: "the first todo's repeat setting") else { return }
        repeatPicker.tap()
        app.buttons["Daily"].tap()

        let createAnother = app.buttons["task-editor-save-another"]
        guard require(createAnother, in: app, description: "Save & Create Another") else { return }
        XCTAssertTrue(createAnother.isEnabled)
        createAnother.tap()
        let confirmation = app.descendants(matching: .any)
            .matching(identifier: "task-editor-saved-confirmation").firstMatch
        guard require(confirmation, in: app, description: "the saved confirmation") else { return }
        XCTAssertTrue(editor.exists, "Repeated entry should keep the editor open")
        XCTAssertFalse(createAnother.isEnabled, "The next todo needs its own name")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Create another after saving a scheduled todo"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        name.typeText("Repeated second")
        let save = app.buttons["task-editor-save"]
        XCTAssertTrue(save.isEnabled, "The previous relative expression must not block the next todo")
        save.tap()
        guard requireEditorDismissed(editor, after: "finishing repeated entry", in: app) else { return }

        app.terminate()
        app.launchArguments.removeAll { $0 == reset }
        app.launch()
        guard selectFilter("Active", in: app) else { return }
        let taskList = app.descendants(matching: .any)
            .matching(identifier: "task-list").firstMatch
        for (taskName, hasDate) in [("Repeated first", true), ("Repeated second", false)] {
            guard let task = requireTaskRow(
                named: taskName, state: "Pending", in: app, taskList: taskList,
                description: "the persisted \(taskName) todo"
            ) else { return }
            XCTAssertEqual(
                task.label.contains("Recurring todo"), hasDate,
                "Save & Create Another must clear recurrence with the schedule"
            )
            task.tap()
            guard require(editor, in: app, description: "the saved repeated-entry todo") else { return }
            XCTAssertEqual(app.textFields["task-editor-name"].value as? String, taskName)
            XCTAssertEqual(app.textFields["task-editor-tags"].value as? String, "focus")
            XCTAssertEqual(app.buttons["work project"].value as? String, "Selected")
            XCTAssertEqual(
                app.switches["task-editor-due-date-toggle"].value as? String,
                hasDate ? "1" : "0",
                "The next todo must not inherit the first todo's schedule"
            )
            XCTAssertFalse(app.buttons["task-editor-save-another"].exists)
            app.buttons["Cancel"].tap()
        }
    }

    @MainActor
    func testInboxIncludesUndatedTasksAndRemovesOrganizedOrCompletedTasks() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let reset = "-ui-testing-reset-workspace"
        app.launchArguments = ["-ui-testing", reset]
        app.launch()
        guard selectFilter("Active", in: app) else { return }
        app.buttons["project-sidebar-toggle"].tap()
        app.buttons["project-filter-work"].tap()
        app.buttons["project-sidebar-toggle"].tap()
        let inbox = app.buttons["inbox-open"]
        guard require(inbox, in: app, description: "the first-class Inbox sidebar action") else { return }
        let inboxCount = app.staticTexts["inbox-open-count"]
        guard require(inboxCount, in: app, description: "the Inbox open count") else { return }
        XCTAssertEqual(inboxCount.label, "0", "Project-assigned todos must not count toward Inbox")
        inbox.tap()
        XCTAssertFalse(taskRow(named: "Undated todo", state: "Pending", in: app).exists)
        let editor = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch

        for (name, hasDate) in [("Inbox undated", false), ("Inbox scheduled", true)] {
            app.buttons["task-add"].tap()
            guard require(editor, in: app, description: "a projectless todo editor") else { return }
            let nameField = app.textFields["task-editor-name"]
            nameField.tap()
            nameField.typeText(name)
            if hasDate {
                app.switches["task-editor-due-date-toggle"].tap()
            }
            app.buttons["task-editor-save"].tap()
            guard requireEditorDismissed(editor, after: "capturing an Inbox todo", in: app) else { return }
        }

        app.terminate()
        app.launchArguments.removeAll { $0 == reset }
        app.launch()
        app.buttons["project-sidebar-toggle"].tap()
        app.buttons["project-filter-work"].tap()
        app.buttons["project-sidebar-toggle"].tap()
        guard require(inboxCount, in: app, description: "the persisted Inbox count from Today's Work view") else { return }
        XCTAssertEqual(inboxCount.label, "2", "Inbox counts all active projectless todos, regardless of date or selected project")
        let sidebarScreenshot = XCTAttachment(screenshot: app.screenshot())
        sidebarScreenshot.name = "Inbox open count includes dated and undated tasks outside the current project"
        sidebarScreenshot.lifetime = .keepAlways
        add(sidebarScreenshot)
        inbox.tap()
        let undated = taskRow(named: "Inbox undated", state: "Pending", in: app)
        let scheduled = taskRow(named: "Inbox scheduled", state: "Pending", in: app)
        guard require(undated, in: app, description: "the undated Inbox todo after relaunch"),
              require(scheduled, in: app, description: "the dated Inbox todo after relaunch")
        else { return }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Inbox includes both dated and undated projectless todos"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        undated.tap()
        guard require(editor, in: app, description: "the Inbox triage editor") else { return }
        app.buttons["home project"].tap()
        let tags = app.textFields["task-editor-tags"]
        tags.tap()
        tags.typeText("triaged")
        app.buttons["task-editor-save"].tap()
        guard requireEditorDismissed(editor, after: "assigning a project and tag", in: app) else { return }
        XCTAssertTrue(undated.waitForNonExistence(timeout: 8))
        app.buttons["project-sidebar-toggle"].tap()
        guard require(inboxCount, in: app, description: "the Inbox count after organizing a todo") else { return }
        XCTAssertEqual(inboxCount.label, "1")
        inbox.tap()
        let completion = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "task-toggle-completion-")
        ).firstMatch
        guard require(completion, in: app, description: "the remaining Inbox todo completion circle") else { return }
        completion.tap()
        XCTAssertTrue(scheduled.waitForNonExistence(timeout: 8))

        app.terminate()
        app.launch()
        guard selectFilter("Inbox", in: app) else { return }
        XCTAssertFalse(undated.exists)
        XCTAssertFalse(scheduled.exists)
        app.buttons["project-sidebar-toggle"].tap()
        guard require(inboxCount, in: app, description: "the Inbox count after completing its last todo and relaunching") else { return }
        XCTAssertEqual(inboxCount.label, "0", "Terminal projectless todos must not count")
        app.buttons["project-filter-home"].tap()
        XCTAssertTrue(app.buttons["task-filter-active"].isSelected)
        guard require(undated, in: app, description: "the organized todo in its project") else { return }
        undated.tap()
        guard require(editor, in: app, description: "the saved triage fields") else { return }
        XCTAssertEqual(app.buttons["home project"].value as? String, "Selected")
        XCTAssertEqual(tags.value as? String, "triaged")
        app.buttons["Cancel"].tap()
        app.buttons["project-sidebar-toggle"].tap()
        app.buttons["project-filter-all"].tap()
        guard selectFilter("All", in: app) else { return }
        _ = require(
            taskRow(named: "Inbox scheduled", state: "Done", in: app),
            in: app, description: "the completed todo outside Inbox"
        )
        app.buttons["project-sidebar-toggle"].tap()
        guard require(inboxCount, in: app, description: "the Inbox count while All includes terminal todos") else { return }
        XCTAssertEqual(inboxCount.label, "0")
    }

    @MainActor
    func testSafariShareSavesSourceContextToInboxOffline() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let reset = "-ui-testing-reset-workspace"
        app.launchArguments = ["-ui-testing", reset]
        app.launch()
        guard selectFilter("Inbox", in: app) else { return }

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        if safari.buttons["Continue"].waitForExistence(timeout: 3) {
            safari.buttons["Continue"].tap()
        }
        let address = safari.textFields.matching(
            NSPredicate(format: "identifier IN %@", ["TabBarItemTitle", "URL"])
        ).firstMatch
        guard require(address, in: safari, description: "Safari's address field") else { return }
        address.tap()
        let sourceURL = "https://example.com/?otodo-capture=27"
        safari.typeText(sourceURL + "\n")
        let pageTitle = safari.webViews.staticTexts["Example Domain"]
        guard require(pageTitle, in: safari, description: "the source webpage", timeout: 20) else { return }
        let shareButton = safari.buttons["Share"]
        if !shareButton.isHittable {
            let more = safari.buttons["More"]
            guard require(more, in: safari, description: "Safari's page actions") else { return }
            more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if !shareButton.waitForExistence(timeout: 2) {
                // Safari's first-run More tip intercepts the initial tap.
                pageTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }
        guard require(shareButton, in: safari, description: "Safari's Share action") else { return }
        shareButton.tap()
        let otodo = safari.cells.containing(.staticText, identifier: "OTodo").firstMatch
        if !otodo.waitForExistence(timeout: 3) {
            let more = safari.cells.matching(identifier: "shareCell")
                .containing(.staticText, identifier: "More").firstMatch
            guard require(more, in: safari, description: "the Share sheet's additional apps") else { return }
            more.tap()
        }
        guard require(otodo, in: safari, description: "OTodo in the system Share sheet") else { return }
        otodo.tap()

        let captureName = safari.textFields["share-capture-name"]
        guard require(captureName, in: safari, description: "the OTodo Share capture editor", timeout: 15) else { return }
        XCTAssertEqual(captureName.value as? String, "Example Domain")
        let context = safari.textViews["share-capture-context"]
        guard require(context, in: safari, description: "the source Markdown context") else { return }
        XCTAssertTrue((context.value as? String)?.contains(sourceURL) == true)
        XCTAssertTrue((context.value as? String)?.contains("Example Domain") == true)
        let screenshot = XCTAttachment(screenshot: safari.screenshot())
        screenshot.name = "System Share capture preserves webpage title and URL"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        safari.buttons["share-capture-save"].tap()
        XCTAssertTrue(captureName.waitForNonExistence(timeout: 10))

        app.activate()
        guard selectFilter("Inbox", in: app) else { return }
        let captured = taskRow(named: "Example Domain", state: "Pending", in: app)
        guard require(captured, in: app, description: "the externally captured Inbox todo") else { return }
        app.terminate()
        app.launchArguments.removeAll { $0 == reset }
        app.launch()
        guard selectFilter("Inbox", in: app) else { return }
        guard require(captured, in: app, description: "the durable shared todo after relaunch") else { return }
        captured.tap()
        let editor = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
        guard require(editor, in: app, description: "the captured todo's original context") else { return }
        XCTAssertEqual(app.switches["task-editor-due-date-toggle"].value as? String, "0")
        let notes = app.textViews["Todo notes"]
        if !notes.isHittable { editor.swipeUp() }
        guard require(notes, in: app, description: "the saved Markdown notes") else { return }
        XCTAssertTrue((notes.value as? String)?.contains(sourceURL) == true)
        XCTAssertTrue((notes.value as? String)?.contains("Example Domain") == true)
    }

    @MainActor
    func testUpcomingGroupsActiveTasksAndRetainsProjectScope() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-upcoming"]
        app.launch()
        let sidebar = app.buttons["project-sidebar-toggle"]
        guard require(sidebar, in: app, description: "the agenda sidebar") else { return }
        sidebar.tap()
        app.buttons["project-filter-work"].tap()
        sidebar.tap()
        app.buttons["upcoming-open"].tap()
        let future = taskRow(named: "Future todo", state: "Pending", in: app)
        guard require(future, in: app, description: "the work project's upcoming task") else { return }
        XCTAssertFalse(taskRow(named: "Overdue todo", state: "Pending", in: app).exists)
        XCTAssertFalse(taskRow(named: "Seed todo", state: "Pending", in: app).exists)
        XCTAssertTrue(future.label.contains("at 09:15"), "Agenda rows retain exact due times")
        sidebar.tap()
        XCTAssertEqual(app.buttons["project-filter-work"].value as? String, "Selected")
        XCTAssertTrue(app.buttons["upcoming-open"].isSelected)
        app.buttons["project-filter-all"].tap()

        let taskList = app.descendants(matching: .any).matching(identifier: "task-list").firstMatch
        for (group, name) in [
            ("overdue", "Overdue todo"), ("today", "Seed todo"), ("tomorrow", "Future todo"),
            ("next-seven-days", "Week review"), ("later", "Later review"), ("no-date", "Undated todo"),
        ] {
            let row = taskRow(named: name, state: "Pending", in: app)
            for _ in 0..<8 {
                if row.exists && row.isHittable { break }
                taskList.swipeUp(velocity: .slow)
            }
            guard require(row, in: app, description: "\(name) in Upcoming") else { return }
            let header = app.descendants(matching: .any)
                .matching(identifier: "upcoming-section-\(group)").firstMatch
            guard require(header, in: app, description: "the \(group) agenda section") else { return }
            XCTAssertLessThan(header.frame.minY, row.frame.minY)
            XCTAssertEqual(app.buttons.matching(identifier: row.identifier).count, 1)
            XCTAssertFalse(taskRow(named: "Completed overdue todo", state: "Done", in: app).exists)
            if group == "tomorrow" || group == "no-date" {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Upcoming agenda \(group) sections"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
        }
    }

    @MainActor
    func testUpcomingBulkReschedulePreservesMixedTimesAndDetailsOffline() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let reset = "-ui-testing-reset-workspace"
        app.launchArguments = ["-ui-testing", reset, "-ui-testing-upcoming"]
        app.launch()
        let sidebar = app.buttons["project-sidebar-toggle"]
        guard require(sidebar, in: app, description: "the weekly review sidebar") else { return }
        sidebar.tap()
        app.buttons["project-filter-work"].tap()
        sidebar.tap()
        app.buttons["upcoming-open"].tap()
        let select = app.buttons["upcoming-select"]
        guard require(select, in: app, description: "Upcoming's multi-selection action") else { return }
        select.tap()
        let taskList = app.descendants(matching: .any).matching(identifier: "task-list").firstMatch
        let reschedule = app.buttons["upcoming-reschedule"]
        for name in ["Future todo", "Week review"] {
            let row = taskRow(named: name, state: "Pending", in: app)
            for _ in 0..<6 {
                // XCTest may report a row behind the pinned toolbar as hittable.
                if row.exists && row.isHittable && row.frame.maxY < reschedule.frame.minY {
                    break
                }
                taskList.swipeUp(velocity: .slow)
            }
            guard require(row, in: app, description: "the selected \(name) task") else { return }
            XCTAssertLessThan(row.frame.maxY, reschedule.frame.minY, "Scroll the whole row above the toolbar")
            row.tap()
            XCTAssertTrue(row.isSelected)
        }
        guard require(reschedule, in: app, description: "the bulk reschedule action") else { return }
        XCTAssertTrue(reschedule.isEnabled)
        reschedule.tap()
        let sheet = app.descendants(matching: .any).matching(identifier: "task-reschedule").firstMatch
        guard require(sheet, in: app, description: "the batch schedule editor") else { return }
        let save = app.buttons["task-reschedule-save"]
        XCTAssertFalse(save.isEnabled, "A batch must not overwrite schedules before any field is changed")
        let relative = app.textFields["task-reschedule-relative-due-date"]
        relative.tap()
        relative.typeText("in 5 days")
        app.buttons["task-reschedule-relative-due-apply"].tap()
        XCTAssertTrue(save.isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Bulk date change keeps each task's existing time"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        save.tap()
        guard requireEditorDismissed(sheet, after: "bulk rescheduling offline", in: app) else { return }

        app.terminate()
        app.launchArguments.removeAll { $0 == reset }
        app.launch()
        guard selectFilter("Active", in: app) else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let date = calendar.date(byAdding: .day, value: 5, to: Date())!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let expectedDate = String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
        for (name, time) in [("Future todo", "09:15"), ("Week review", "16:45")] {
            guard let row = requireTaskRow(
                named: name, state: "Pending", in: app, taskList: taskList,
                description: "the durably rescheduled \(name) task"
            ) else { return }
            XCTAssertTrue(row.label.contains("Due: \(expectedDate) at \(time)"))
            XCTAssertTrue(row.label.contains("Projects: work"))
            XCTAssertTrue(row.label.contains("Tags: focus"))
            if name == "Future todo" {
                row.tap()
                let editor = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
                guard require(editor, in: app, description: "the rescheduled task's unchanged notes") else { return }
                let notes = app.textViews["Todo notes"]
                for _ in 0..<4 {
                    if notes.exists && notes.isHittable { break }
                    editor.swipeUp()
                }
                XCTAssertEqual(notes.value as? String, "Review invoice 123\nSend receipt")
                app.buttons["Cancel"].tap()
            }
        }
        XCTAssertTrue(taskRow(named: "Undated todo", state: "Pending", in: app).exists)
        XCTAssertFalse(taskRow(named: "Undated todo", state: "Pending", in: app).label.contains("Due:"))
    }

    @MainActor
    func testTodoSortingPersistsAcrossRelaunchAndKeepsProjectScope() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let reset = "-ui-testing-reset-workspace"
        app.launchArguments = ["-ui-testing", reset]
        app.launch()
        guard selectFilter("Active", in: app) else { return }

        func assertBefore(_ firstName: String, _ secondName: String, line: UInt = #line) {
            let first = taskRow(named: firstName, state: "Pending", in: app)
            let second = taskRow(named: secondName, state: "Pending", in: app)
            let ordered = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    first.exists && second.exists && first.isHittable && second.isHittable
                        && first.frame.minY < second.frame.minY
                },
                object: nil
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [ordered], timeout: 8), .completed,
                "\(firstName) must appear before \(secondName)", line: line
            )
        }

        assertBefore("Overdue todo", "Seed todo")
        let sort = app.buttons["task-sort"]
        guard require(sort, in: app, description: "the todo sorting menu") else { return }
        for (choice, first, second) in [
            ("Created date (newest first)", "Undated todo", "Future todo"),
            ("Alphabetical (A–Z)", "Future todo", "Overdue todo"),
        ] {
            sort.tap()
            let option = app.buttons[choice]
            guard require(option, in: app, description: "the \(choice) sorting choice") else { return }
            if choice == "Created date (newest first)" {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Todo sorting choices"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            option.tap()
            assertBefore(first, second)
            XCTAssertTrue(app.buttons["task-filter-active"].isSelected)
        }

        app.buttons["project-sidebar-toggle"].tap()
        let work = app.buttons["project-filter-work"]
        guard require(work, in: app, description: "the Work project scope") else { return }
        work.tap()
        assertBefore("Future todo", "Undated todo")
        sort.tap()
        app.buttons["Created date (newest first)"].tap()
        assertBefore("Undated todo", "Future todo")
        XCTAssertFalse(taskRow(named: "Overdue todo", state: "Pending", in: app).exists)

        app.terminate()
        app.launchArguments.removeAll { $0 == reset }
        app.launch()
        guard selectFilter("Active", in: app) else { return }
        assertBefore("Undated todo", "Future todo")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Newest-created todo order restored after relaunch"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["task-sort"].tap()
        app.buttons["Due date (earliest first)"].tap()
        assertBefore("Overdue todo", "Seed todo")
    }

    @MainActor
    func testRecurringOccurrencePersistsAndSeriesCanFinish() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let reset = "-ui-testing-reset-workspace"
        app.launchArguments = ["-ui-testing", reset]
        app.launch()
        guard selectFilter("Active", in: app) else { return }
        app.buttons["task-add"].tap()

        let editor = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
        let name = app.textFields["task-editor-name"]
        guard require(name, in: app, description: "the recurring todo name") else { return }
        name.tap()
        name.typeText("Recurring review in 100 days\n")
        let repeatPicker = app.buttons["task-editor-repeat"]
        for _ in 0..<6 {
            if repeatPicker.exists && repeatPicker.isHittable { break }
            editor.swipeUp()
        }
        guard require(repeatPicker, in: app, description: "the repeat frequency picker") else { return }
        repeatPicker.tap()
        app.buttons["Daily"].tap()
        let interval = app.textFields["task-editor-repeat-interval"]
        guard require(interval, in: app, description: "the repeat interval") else { return }
        interval.tap()
        interval.typeText(XCUIKeyboardKey.delete.rawValue + "0")
        let save = app.buttons["task-editor-save"]
        XCTAssertFalse(save.isEnabled, "A zero interval cannot be saved")
        interval.typeText(XCUIKeyboardKey.delete.rawValue + "2")
        XCTAssertTrue(save.isEnabled)
        let settingsScreenshot = XCTAttachment(screenshot: app.screenshot())
        settingsScreenshot.name = "Create a recurring todo with a two-day interval"
        settingsScreenshot.lifetime = .keepAlways
        add(settingsScreenshot)
        save.tap()
        guard requireEditorDismissed(editor, after: "creating a recurring todo", in: app) else { return }

        let taskList = app.descendants(matching: .any).matching(identifier: "task-list").firstMatch
        guard let row = requireTaskRow(
            named: "Recurring review", state: "Pending", in: app, taskList: taskList,
            description: "the new recurring todo"
        ) else { return }
        let taskID = String(row.identifier.dropFirst("task-row-".count))
        let dueRange = try XCTUnwrap(row.label.range(of: "Due: "))
        let initialDue = String(row.label[dueRange.upperBound...].prefix(10))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let initialDate = try XCTUnwrap(formatter.date(from: initialDue))
        let nextDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: initialDate))
        let nextDue = formatter.string(from: nextDate)

        let circle = app.buttons["task-toggle-completion-\(taskID)"]
        guard require(circle, in: app, description: "the occurrence completion circle") else { return }
        circle.tap()
        let advanced = app.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "task-row-\(taskID)", "State: Pending", "Due: \(nextDue)"
        )).firstMatch
        guard require(advanced, in: app, description: "the same open todo at its next due date") else { return }
        XCTAssertFalse(editor.exists, "Occurrence completion must not open the title editor")

        app.terminate()
        app.launchArguments.removeAll { $0 == reset }
        app.launch()
        guard selectFilter("Active", in: app) else { return }
        taskList.swipeUp()
        guard require(advanced, in: app, description: "the persisted next occurrence after relaunch") else { return }
        advanced.tap()
        guard require(editor, in: app, description: "the recurring todo opened by its title") else { return }
        XCTAssertEqual(name.value as? String, "Recurring review")
        for _ in 0..<6 {
            if interval.exists && interval.isHittable { break }
            editor.swipeUp()
        }
        guard require(interval, in: app, description: "the persisted editable recurrence") else { return }
        XCTAssertEqual(interval.value as? String, "2")
        app.buttons["Cancel"].tap()
        guard requireEditorDismissed(editor, after: "inspecting the next occurrence", in: app) else { return }
        advanced.press(forDuration: 1.2)
        let finish = app.buttons["task-context-finish-series-\(taskID)"]
        guard require(finish, in: app, description: "the explicit finish-series action") else { return }
        let actionsScreenshot = XCTAttachment(screenshot: app.screenshot())
        actionsScreenshot.name = "Recurring todo offers occurrence completion and finish series"
        actionsScreenshot.lifetime = .keepAlways
        add(actionsScreenshot)
        finish.tap()
        XCTAssertTrue(advanced.waitForNonExistence(timeout: 8))

        app.terminate()
        app.launch()
        guard selectFilter("All", in: app) else { return }
        guard let finished = requireTaskRow(
            named: "Recurring review", state: "Done", in: app, taskList: taskList,
            description: "the finished series persisted after relaunch"
        ) else { return }
        XCTAssertEqual(finished.identifier, "task-row-\(taskID)")
        XCTAssertTrue(finished.label.contains("Due: \(nextDue)"), "Finishing the series must not advance its schedule")
        let finishedScreenshot = XCTAttachment(screenshot: app.screenshot())
        finishedScreenshot.name = "Finished recurring series persisted without another occurrence"
        finishedScreenshot.lifetime = .keepAlways
        add(finishedScreenshot)
    }

    @MainActor
    private func selectFilter(
        _ name: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let button = app.buttons["task-filter-\(name.lowercased())"]
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
    private func requireProjectCounts(
        _ expected: [(String?, Int)],
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let sidebarButton = app.buttons["project-sidebar-toggle"]
        guard require(
            sidebarButton, in: app, description: "the project sidebar button", file: file, line: line
        ) else { return false }
        sidebarButton.tap()
        for (project, count) in expected {
            let identifier = project.map { "project-open-count-\($0)" } ?? "project-open-count"
            let badge = app.staticTexts[identifier]
            guard require(
                badge, in: app, description: "the open count for \(project ?? "all projects")", file: file, line: line
            ) else { return false }
            XCTAssertEqual(badge.label, String(count), "Only open todos should count", file: file, line: line)
        }
        return true
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
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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
