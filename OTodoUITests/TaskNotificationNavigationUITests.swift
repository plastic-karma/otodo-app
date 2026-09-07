import XCTest

@MainActor
final class TaskNotificationNavigationUITests: XCTestCase {
    private let targetID = "01ARZ3NDEKTSV4RRFFQ69G5FAX"
    private let seedID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    func testColdNotificationOpensAndEditsExactTaskHiddenByToday() {
        let app = launch(taskID: targetID)
        let name = app.textFields["task-editor-name"]
        assertName("Future todo", in: app)
        XCTAssertFalse(app.buttons["task-editor-save-another"].exists)
        attachScreenshot("Cold reminder opens the future task outside Today", app: app)

        name.tap()
        name.typeText(" opened")
        app.buttons["task-editor-save"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 8), "A consumed reminder must not reopen after Save")
        app.terminate()
        app.launchArguments.removeAll { $0 == "-ui-testing-reset-workspace" }
        app.launch()
        assertName("Future todo opened", in: app)
    }

    func testWarmNotificationWaitsForUnsavedEditorThenOpensTarget() {
        let app = launch(taskID: targetID, warm: true)
        XCTAssertTrue(app.buttons["task-row-\(seedID)"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["task-row-\(targetID)"].exists, "Today hides the reminder target")
        app.buttons["task-add"].tap()
        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText("Keep unsaved draft")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8))
        app.activate()
        assertName("Keep unsaved draft", in: app)
        app.buttons["task-editor-save"].tap()
        assertName("Future todo", in: app)
        attachScreenshot("Warm reminder opens its target after the current draft is saved", app: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 8))

        app.buttons["task-filter-active"].tap()
        let savedDraft = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
            "task-row-", "Keep unsaved draft"
        )).firstMatch
        XCTAssertTrue(savedDraft.waitForExistence(timeout: 8), "The original draft must be saved, not replaced by the notification")
    }

    func testStaleTaskIDDoesNotOpenAnotherCachedTask() {
        let app = launch(taskID: "01ARZ3NDEKTSV4RRFFQ69G5FB9")
        XCTAssertTrue(app.buttons["task-row-\(seedID)"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["task-editor-name"].exists)
        app.buttons["task-row-\(seedID)"].tap()
        assertName("Seed todo", in: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.textFields["task-editor-name"].waitForNonExistence(timeout: 8))
    }

    func testMalformedTaskIDDoesNotOpenEditor() {
        let app = launch(taskID: "not-a-task")
        XCTAssertTrue(app.buttons["task-row-\(seedID)"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["task-editor-name"].exists)
    }

    private func launch(taskID: String, warm: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing", "-ui-testing-reset-workspace",
            "-ui-testing-notification-task", taskID,
        ]
        if warm {
            app.launchArguments.append("-ui-testing-notification-on-activation")
        }
        app.launch()
        return app
    }

    private func assertName(_ expected: String, in app: XCUIApplication) {
        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        let value = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected), object: name
        )
        XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 8), .completed)
    }

    private func attachScreenshot(_ title: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = title
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
