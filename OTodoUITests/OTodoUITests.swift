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
        nameField.typeText("Call mum tomorrow")

        let detection = app.descendants(matching: .any)
            .matching(identifier: "task-editor-detected-due-date")
            .firstMatch
        guard require(
            detection,
            in: app,
            description: "the detected due-date explanation"
        ) else { return }
        XCTAssertTrue(
            detection.label.localizedCaseInsensitiveContains("tomorrow"),
            "The detected phrase should remain identifiable while editing"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Detected due date in todo name"
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
        XCTAssertTrue(
            savedTask.label.contains("Due:"),
            "The detected phrase should become a persisted due date"
        )
        XCTAssertFalse(
            savedTask.label.localizedCaseInsensitiveContains("tomorrow"),
            "The detected phrase should be stripped from the saved name"
        )

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

        newTodoAction.tap()

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
        relativeField.typeText("in 6 hours")

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
        guard require(
            sidebarButton,
            in: app,
            description: "the project sidebar button"
        ) else { return }
        sidebarButton.tap()

        let addProjectButton = app.buttons["project-add"]
        guard require(
            addProjectButton,
            in: app,
            description: "the New Project button"
        ) else { return }
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
    func testWorkspaceVisualDesign() {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ui-testing", "-ui-testing-reset-workspace"])
        app.launch()

        let hero = app.descendants(matching: .any)
            .matching(identifier: "workspace-hero")
            .firstMatch
        guard require(
            hero,
            in: app,
            description: "the workspace focus card"
        ) else { return }
        guard require(
            app.segmentedControls["task-filter"],
            in: app,
            description: "the styled visibility control"
        ) else { return }
        guard require(
            app.buttons["task-add"],
            in: app,
            description: "the floating Add Todo button"
        ) else { return }
        guard require(
            taskRow(named: "Seed todo", state: "Pending", in: app),
            in: app,
            description: "a styled todo card"
        ) else { return }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "OTodo workspace redesign"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
