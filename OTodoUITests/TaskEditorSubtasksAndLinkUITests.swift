import Foundation
import XCTest

final class TaskEditorSubtasksAndLinkUITests: XCTestCase {
    @MainActor
    func testParentAndQueuedChildrenPersistWithLinkAcrossCreateEditAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-subtasks", "-ui-testing-reset-workspace"]
        app.launch()
        openActive(in: app)
        app.buttons["task-add"].tap()
        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText("Linked parent\n")

        let url = app.textFields["task-editor-url"]
        app.revealTaskEditorElement(url)
        url.tap()
        url.typeText("https://example.com/Reference?item=One#Notes")
        queueChild("Discarded child", in: app)
        let remove = app.buttons["task-editor-remove-subtask-0"]
        app.revealTaskEditorElement(remove)
        remove.tap()
        queueChild("First child", in: app)
        attachScreenshot(in: app, name: "New parent with queued subtask and link")

        // Repeat entry must persist the first family without leaking it into the next draft.
        app.buttons["task-editor-save-another"].tap()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "task-editor-saved-confirmation").firstMatch.waitForExistence(timeout: 8))
        name.typeText("Independent repeated parent\n")
        app.revealTaskEditorElement(url)
        XCTAssertFalse(app.buttons["task-editor-clear-url"].exists)
        let childInput = app.textFields["task-editor-subtask-name"]
        app.revealTaskEditorElement(childInput)
        XCTAssertFalse(app.buttons["task-editor-remove-subtask-0"].exists)
        save(in: app)

        relaunch(app)
        openTask("Independent repeated parent", in: app)
        app.revealTaskEditorElement(childInput)
        XCTAssertFalse(existingChild("First child", in: app).exists)
        app.buttons["Cancel"].tap()
        openTask("Linked parent", in: app)
        app.revealTaskEditorElement(url)
        XCTAssertEqual(url.value as? String, "https://example.com/Reference?item=One#Notes")
        let openLink = app.descendants(matching: .any).matching(identifier: "task-editor-open-url").firstMatch
        app.revealTaskEditorElement(openLink)
        openLink.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let browserOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue),
            object: safari
        )
        XCTAssertEqual(XCTWaiter.wait(for: [browserOpened], timeout: 8), .completed,
                       "The link must open only after the explicit tap")
        app.activate()
        let firstChild = existingChild("First child", in: app)
        app.revealTaskEditorElement(firstChild)
        XCTAssertTrue(firstChild.exists, "The saved child must be a direct child of this parent")
        XCTAssertFalse(existingChild("Discarded child", in: app).exists)
        queueChild("Second child", in: app)
        app.revealTaskEditorElement(url)
        app.buttons["task-editor-clear-url"].tap()
        XCTAssertFalse(openLink.exists)
        save(in: app)

        relaunch(app)
        openTask("Linked parent", in: app)
        app.revealTaskEditorElement(url)
        XCTAssertFalse(app.buttons["task-editor-clear-url"].exists, "Clearing the link must survive relaunch")
        XCTAssertFalse(openLink.exists)
        app.revealTaskEditorElement(existingChild("First child", in: app))
        XCTAssertTrue(existingChild("First child", in: app).exists)
        app.revealTaskEditorElement(existingChild("Second child", in: app))
        XCTAssertTrue(existingChild("Second child", in: app).exists,
                      "Editing a parent must append its queued children without replacing existing children")
        attachScreenshot(in: app, name: "Offline parent retains both saved direct children")
    }

    @MainActor
    func testQueuedChildrenKeepProjectsFromEachParentSave() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-subtasks", "-ui-testing-reset-workspace"]
        app.launch()
        openActive(in: app)
        openTask("Hierarchy parent", in: app)
        queueChild("Before project change", in: app)
        save(in: app)

        openTask("Hierarchy parent", in: app)
        let details = app.buttons["task-editor-details"]
        app.revealTaskEditorElement(details)
        details.tap()
        let work = app.buttons["work project"]
        app.revealTaskEditorElement(work)
        XCTAssertEqual(work.value as? String, "Selected")
        work.tap()
        app.buttons["home project"].tap()
        queueChild("After project change", in: app)
        save(in: app)

        relaunch(app)
        for (child, selected, unselected) in [
            ("Before project change", "work project", "home project"),
            ("After project change", "home project", "work project"),
        ] {
            openTask(child, in: app)
            app.revealTaskEditorElement(details)
            details.tap()
            app.revealTaskEditorElement(app.buttons[selected])
            XCTAssertEqual(app.buttons[selected].value as? String, "Selected")
            XCTAssertEqual(app.buttons[unselected].value as? String, "Not selected")
            attachScreenshot(in: app, name: "\(child) keeps the projects from its parent's save")
            app.buttons["Cancel"].tap()
        }
    }

    @MainActor
    func testSubtaskSwipesPreserveParentDraftAndPersistChildActions() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-subtasks", "-ui-testing-reset-workspace"]
        app.launch()
        openActive(in: app)
        openTask("Hierarchy parent", in: app)
        let name = app.textFields["task-editor-name"]
        name.tap()
        name.typeText(" amended\n")
        let unsavedName = try XCTUnwrap(name.value as? String)
        XCTAssertNotEqual(unsavedName, "Hierarchy parent")
        let childID = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
        let child = existingChild("Hierarchy child", in: app)

        revealLeadingActions(for: child, in: app)
        XCTAssertTrue(app.buttons["task-complete-\(childID)"].exists)
        XCTAssertTrue(app.buttons["task-add-subtask-\(childID)"].exists)
        let reschedule = app.buttons["task-reschedule-\(childID)"]
        XCTAssertTrue(reschedule.exists)
        attachScreenshot(in: app, name: "Saved subtask exposes the same leading actions as the main list")
        reschedule.tap()
        let relative = app.textFields["task-reschedule-relative-due-date"]
        XCTAssertTrue(relative.waitForExistence(timeout: 8))
        relative.tap()
        relative.typeText("in 2 days")
        app.buttons["task-reschedule-relative-due-apply"].tap()
        app.buttons["task-reschedule-save"].tap()
        XCTAssertTrue(relative.waitForNonExistence(timeout: 8))
        app.revealTaskEditorElement(child)
        let due = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 2, to: .now)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let parts = calendar.dateComponents([.year, .month, .day], from: due)
        let dueKey = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        XCTAssertTrue(child.label.contains("Due: \(dueKey)"))

        revealLeadingActions(for: child, in: app)
        app.buttons["task-add-subtask-\(childID)"].tap()
        XCTAssertTrue(app.navigationBars["New Todo"].waitForExistence(timeout: 8))
        let nestedEditor = app.collectionViews.matching(identifier: "task-editor").element(boundBy: 1)
        let nestedName = nestedEditor.textFields["task-editor-name"]
        nestedName.tap()
        nestedName.typeText("Swipe grandchild\n")
        app.navigationBars["New Todo"].buttons["task-editor-save"].tap()
        XCTAssertTrue(app.navigationBars["New Todo"].waitForNonExistence(timeout: 8))

        revealLeadingActions(for: child, in: app)
        app.buttons["task-complete-\(childID)"].tap()
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "State: Done"), object: child
        )
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 8), .completed)
        revealTrailingActions(for: child, in: app)
        app.buttons["task-delete-\(childID)"].tap()
        let refusal = app.descendants(matching: .any).matching(identifier: "subtask-action-error").firstMatch
        app.revealTaskEditorElement(refusal)
        XCTAssertTrue(refusal.label.localizedCaseInsensitiveContains("child"))
        XCTAssertTrue(child.exists, "Delete must retain a nonleaf just as the main list does")

        app.revealTaskEditorElement(child)
        child.tap()
        let grandchild = existingChild("Swipe grandchild", in: app)
        app.revealTaskEditorElement(grandchild)
        XCTAssertTrue(grandchild.label.contains("State: Done"))
        let grandchildID = String(grandchild.identifier.dropFirst("task-editor-existing-subtask-".count))
        revealTrailingActions(for: grandchild, in: app)
        app.buttons["task-delete-\(grandchildID)"].tap()
        XCTAssertTrue(grandchild.waitForNonExistence(timeout: 8))
        app.navigationBars.matching(identifier: "Edit Todo").element(boundBy: 1).buttons["Cancel"].tap()
        revealTrailingActions(for: child, in: app)
        app.buttons["task-delete-\(childID)"].tap()
        XCTAssertTrue(child.waitForNonExistence(timeout: 8))
        app.revealTaskEditorElement(name)
        XCTAssertEqual(name.value as? String, unsavedName, "Child actions must not replace unsaved parent fields")
        save(in: app)

        relaunch(app)
        openTask(unsavedName, in: app)
        let input = app.textFields["task-editor-subtask-name"]
        app.revealTaskEditorElement(input)
        XCTAssertFalse(existingChild("Hierarchy child", in: app).exists)
        attachScreenshot(in: app, name: "Parent draft and subtask deletions persist after offline relaunch")
    }

    @MainActor
    private func revealLeadingActions(for row: XCUIElement, in app: XCUIApplication) {
        app.revealTaskEditorElement(row)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        )
    }

    @MainActor
    private func revealTrailingActions(for row: XCUIElement, in app: XCUIApplication) {
        app.revealTaskEditorElement(row)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        )
    }

    @MainActor
    func testLegacyStoreDisablesSubtasksAndRejectsUnsafeLinkWithoutLosingDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace"]
        app.launch()
        openActive(in: app)
        app.buttons["task-add"].tap()
        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText("Legacy linked task\n")
        let url = app.textFields["task-editor-url"]
        app.revealTaskEditorElement(url)
        url.tap()
        url.typeText("javascript:alert(1)")
        XCTAssertFalse(app.buttons["task-editor-save"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "task-editor-open-url").firstMatch.exists)
        let unavailable = app.staticTexts["task-editor-subtasks-unavailable"]
        app.revealTaskEditorElement(unavailable)
        XCTAssertTrue(unavailable.exists)
        XCTAssertFalse(app.textFields["task-editor-subtask-name"].exists)
        attachScreenshot(in: app, name: "Legacy store explains subtasks while invalid link blocks save")
        app.revealTaskEditorElement(url)
        app.buttons["task-editor-clear-url"].tap()
        url.tap()
        url.typeText("https://example.com/legacy")
        save(in: app)
        relaunch(app)
        openTask("Legacy linked task", in: app)
        app.revealTaskEditorElement(url)
        XCTAssertEqual(url.value as? String, "https://example.com/legacy")
        app.revealTaskEditorElement(unavailable)
        XCTAssertTrue(unavailable.exists, "Saving an additive link must not upgrade the store schema")
    }

    @MainActor
    private func queueChild(_ title: String, in app: XCUIApplication) {
        let input = app.textFields["task-editor-subtask-name"]
        app.revealTaskEditorElement(input)
        input.tap()
        input.typeText(title)
        XCTAssertFalse(app.buttons["task-editor-save"].isEnabled,
                       "Unqueued typing must be added or cleared before saving")
        let add = app.buttons["task-editor-subtask-add"]
        app.revealTaskEditorElement(add)
        add.tap()
        let readyToSave = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: app.buttons["task-editor-save"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [readyToSave], timeout: 8), .completed)
    }

    @MainActor
    private func existingChild(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "task-editor-existing-subtask-", title
        )).firstMatch
    }

    @MainActor
    private func relaunch(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments.removeAll { $0 == "-ui-testing-reset-workspace" }
        app.launch()
        openActive(in: app)
    }

    @MainActor
    private func openActive(in app: XCUIApplication) {
        let active = app.buttons["task-filter-active"]
        XCTAssertTrue(active.waitForExistence(timeout: 8))
        active.tap()
    }

    @MainActor
    private func openTask(_ title: String, in app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
            "task-row-", "\(title). State: Pending"
        )).firstMatch
        let list = app.descendants(matching: .any).matching(identifier: "task-list").firstMatch
        let navigationBar = app.navigationBars.firstMatch
        let syncStatus = app.descendants(matching: .any).matching(identifier: "sync-status").firstMatch
        func isUnobscured() -> Bool {
            guard row.exists && row.isHittable else { return false }
            return row.frame.minY >= navigationBar.frame.maxY
                && row.frame.maxY <= syncStatus.frame.minY
        }
        for _ in 0..<8 {
            if isUnobscured() { break }
            list.swipeUp()
        }
        for _ in 0..<8 {
            if isUnobscured() { break }
            list.swipeDown()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(isUnobscured(), "Task row must be clear of navigation and the sync footer")
        row.tap()
        XCTAssertTrue(app.textFields["task-editor-name"].waitForExistence(timeout: 8))
    }

    @MainActor
    private func save(in app: XCUIApplication) {
        let editor = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
        app.buttons["task-editor-save"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 8))
    }

    @MainActor
    private func attachScreenshot(in app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
