import Foundation
import XCTest

@MainActor
final class TaskInProgressUITests: XCTestCase {
    private let taskID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    func testStartPersistsOfflinePreservesMetadataAndStillCompletes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-in-progress", "-ui-testing-light",
        ]
        app.launch()
        defer { app.terminate() }

        let row = app.buttons["task-row-\(taskID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let metadata = row.label.components(separatedBy: ". ").filter {
            $0.hasPrefix("Due:") || $0.hasPrefix("Projects:") || $0.hasPrefix("Tags:")
        }
        let notes = "Keep the original plan\nDiscuss the open questions."
        row.tap()
        let notesField = app.textViews["task-editor-notes"]
        app.revealTaskEditorElement(notesField)
        notesField.tap()
        notesField.typeText(notes)
        saveEditor(in: app)

        row.press(forDuration: 1.2)
        let start = app.buttons["task-context-start-\(taskID)"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()
        assertState("In Progress", of: row)
        XCTAssertTrue(app.buttons["task-filter-today"].isSelected,
                      "Starting work must not move the task out of Today")
        assertMetadata(metadata, of: row)
        app.buttons["task-filter-active"].tap()
        assertState("In Progress", of: row)
        revealRow(row, in: app)
        capture("In Progress remains in Active — light", in: app)
        let accessibility = XCTAttachment(string: row.label)
        accessibility.name = "In Progress task accessibility description"
        accessibility.lifetime = .keepAlways
        add(accessibility)

        // Drop both reset and configuration flags: only the durable cache may restore the state.
        relaunchOffline(app)
        assertState("In Progress", of: row)
        XCTAssertTrue(app.buttons["task-filter-today"].isSelected)
        assertMetadata(metadata, of: row)
        row.tap()
        app.revealTaskEditorElement(notesField)
        XCTAssertEqual(notesField.value as? String, notes)
        let picker = statePicker(in: app)
        XCTAssertTrue(picker.label.contains("In Progress"), picker.debugDescription)
        capture("In Progress in the native state picker — light", in: app)
        cancelEditor(in: app)

        row.press(forDuration: 1.2)
        let reset = app.buttons["task-context-reset-state-\(taskID)"]
        XCTAssertTrue(reset.waitForExistence(timeout: 8))
        reset.tap()
        assertState("Pending", of: row)
        assertMetadata(metadata, of: row)
        relaunchOffline(app)
        assertState("Pending", of: row)

        // The editor has its own draft/save path, independent of the immediate context action.
        row.tap()
        statePicker(in: app).tap()
        let inProgress = app.buttons["In Progress"]
        XCTAssertTrue(inProgress.waitForExistence(timeout: 8))
        inProgress.tap()
        saveEditor(in: app)
        assertState("In Progress", of: row)
        relaunchOffline(app)
        assertState("In Progress", of: row)
        assertMetadata(metadata, of: row)
        app.buttons["task-filter-active"].tap()
        assertState("In Progress", of: row)
        revealRow(row, in: app)
        let complete = app.buttons["task-toggle-completion-\(taskID)"]
        XCTAssertTrue(complete.waitForExistence(timeout: 8))
        complete.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 8),
                      "Completing in-progress work must remove it from Active")
        app.buttons["task-filter-all"].tap()
        assertState("Done", of: row)
        revealRow(row, in: app)
        row.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["task-context-delete-\(taskID)"].waitForExistence(timeout: 8))
        XCTAssertFalse(start.exists, "Terminal work must not offer Start")
    }

    func testAbsentStateRequiresConfirmationAndOfflineSetupLeavesTaskUnchanged() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace"]
        app.launch()
        defer { app.terminate() }

        let row = app.buttons["task-row-\(taskID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let originalLabel = row.label
        row.tap()
        let originalState = statePicker(in: app).label
        let enable = app.buttons["task-editor-enable-in-progress"]
        app.revealTaskEditorElement(enable)
        XCTAssertFalse(app.buttons["Add state"].exists)
        capture("Workspace workflow setup", in: app)
        cancelEditor(in: app)

        // Merely opening Details must not add a shared state, even across an offline launch.
        relaunchOffline(app)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertEqual(row.label, originalLabel)
        row.tap()
        XCTAssertEqual(statePicker(in: app).label, originalState)
        app.revealTaskEditorElement(enable)
        enable.tap()
        let confirm = app.buttons["Add state"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        capture("Shared workflow confirmation", in: app)
        confirm.tap()
        let error = app.descendants(matching: .any).matching(
            identifier: "task-editor-workflow-error"
        ).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 8), "Offline setup must report its failure")
        app.revealTaskEditorElement(error)
        capture("Offline workflow setup failure", in: app)
        XCTAssertEqual(statePicker(in: app).label, originalState,
                       "Failed setup must leave the task draft untouched")
        cancelEditor(in: app)

        relaunchOffline(app)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertEqual(row.label, originalLabel)
        row.tap()
        XCTAssertEqual(statePicker(in: app).label, originalState)
        app.revealTaskEditorElement(enable)
        XCTAssertTrue(enable.isEnabled, "Failed setup must not persist an in-progress definition")
    }

    private func statePicker(in app: XCUIApplication) -> XCUIElement {
        let details = app.buttons["task-editor-details"]
        app.revealTaskEditorElement(details)
        if details.value as? String != "Expanded" { details.tap() }
        let picker = app.buttons["task-editor-state"]
        app.revealTaskEditorElement(picker)
        return picker
    }

    private func saveEditor(in app: XCUIApplication) {
        let done = app.buttons["task-editor-keyboard-done"]
        if app.keyboards.firstMatch.exists {
            XCTAssertTrue(done.waitForExistence(timeout: 8))
            done.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 8))
        }
        let save = app.buttons["task-editor-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.textFields["task-editor-name"].waitForNonExistence(timeout: 8))
    }

    private func cancelEditor(in app: XCUIApplication) {
        app.navigationBars["Edit Todo"].buttons["Cancel"].tap()
        XCTAssertTrue(app.textFields["task-editor-name"].waitForNonExistence(timeout: 8))
    }

    private func relaunchOffline(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments = ["-ui-testing", "-ui-testing-light"]
        app.launch()
        XCTAssertTrue(app.buttons["task-filter-today"].waitForExistence(timeout: 10))
    }

    private func assertState(_ state: String, of row: XCUIElement) {
        let stateChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", "State: \(state)"),
            object: row
        )
        XCTAssertEqual(XCTWaiter.wait(for: [stateChanged], timeout: 8), .completed)
    }

    private func assertMetadata(_ metadata: [String], of row: XCUIElement) {
        for value in metadata {
            XCTAssertTrue(row.label.contains(value), "Changing state must preserve \(value)")
        }
    }

    private func revealRow(_ row: XCUIElement, in app: XCUIApplication) {
        let list = app.descendants(matching: .any).matching(identifier: "task-list").firstMatch
        let navigation = app.navigationBars.firstMatch
        let footer = app.descendants(matching: .any).matching(identifier: "sync-status").firstMatch
        func isUnobscured() -> Bool {
            guard row.exists, row.isHittable else { return false }
            let bottom = footer.exists ? footer.frame.minY : app.frame.maxY
            return row.frame.minY >= navigation.frame.maxY && row.frame.maxY <= bottom
        }
        for _ in 0..<6 where !isUnobscured() { list.swipeUp() }
        for _ in 0..<6 where !isUnobscured() { list.swipeDown() }
        XCTAssertTrue(isUnobscured(), "The state surface must be clear of navigation and the sync footer")
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
