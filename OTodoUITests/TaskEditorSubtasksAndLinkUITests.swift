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
        for _ in 0..<8 {
            if row.exists && row.isHittable { break }
            list.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8))
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
