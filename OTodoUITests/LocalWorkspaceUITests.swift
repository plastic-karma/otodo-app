import XCTest

@MainActor
final class LocalWorkspaceUITests: XCTestCase {
    func testNoAccountOnboardingPersistsProjectsSubtasksAndAttachmentsAcrossRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-local-onboarding", "-ui-testing-reset-workspace", "-ui-testing-attachment-import"]
        app.launch()
        defer { app.terminate() }
        let local = app.buttons["workspace.use-local"]
        XCTAssertTrue(local.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["authentication.start"].exists, "This scenario has no OAuth configuration")
        local.tap()
        XCTAssertTrue(app.buttons["task-add"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["sync-refresh"].exists)

        app.buttons["task-add"].press(forDuration: 1.2)
        let addProject = app.buttons["project-add"]
        XCTAssertTrue(addProject.waitForExistence(timeout: 8))
        addProject.tap()
        let projectName = app.textFields["project-editor-name"]
        XCTAssertTrue(projectName.waitForExistence(timeout: 8))
        projectName.tap()
        projectName.typeText("Local plans")
        app.buttons["project-editor-save"].tap()
        XCTAssertTrue(projectName.waitForNonExistence(timeout: 8))

        app.buttons["task-add"].tap()
        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText("Local parent\n")
        let child = app.textFields["task-editor-subtask-name"]
        app.revealTaskEditorElement(child)
        child.tap()
        child.typeText("Local child")
        app.buttons["task-editor-subtask-add"].tap()
        let sample = app.buttons["attachment-import-sample"]
        app.revealTaskEditorElement(sample)
        sample.tap()
        let imported = app.staticTexts["sample.txt"]
        app.revealTaskEditorElement(imported)
        XCTAssertTrue(imported.waitForExistence(timeout: 8))
        let saveReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["task-editor-save"])
        XCTAssertEqual(XCTWaiter.wait(for: [saveReady], timeout: 8), .completed)
        app.buttons["task-editor-save"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 8))

        app.terminate()
        app.launchArguments.removeAll { $0 == "-ui-testing-reset-workspace" }
        app.launch()
        XCTAssertTrue(app.buttons["task-add"].waitForExistence(timeout: 10), "A saved local selection must reopen without a token")
        XCTAssertFalse(local.exists)
        XCTAssertFalse(app.buttons["sync-refresh"].exists)
        app.buttons["task-filter-all"].tap()
        let parent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "task-row-", "Local parent")).firstMatch
        XCTAssertTrue(parent.waitForExistence(timeout: 8))
        XCTAssertTrue(parent.label.contains("local-plans"))
        parent.tap()
        let existingChild = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "task-editor-existing-subtask-", "Local child")).firstMatch
        app.revealTaskEditorElement(existingChild)
        XCTAssertTrue(existingChild.exists)
        let openAttachment = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "attachment-open.")).firstMatch
        app.revealTaskEditorElement(openAttachment)
        XCTAssertTrue(imported.exists)
        openAttachment.tap()
        let preview = app.otherElements["QLPreviewControllerView"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let contents = preview.textViews.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Attachment UI test", "Attachment UI test")).firstMatch
        XCTAssertTrue(contents.waitForExistence(timeout: 10), "Local primary file bytes must survive the editor cleanup and process restart")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "No-account local attachment survives relaunch"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["attachment-preview-close"].tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 8))
        app.buttons["Cancel"].tap()

        app.buttons["project-sidebar-toggle"].tap()
        let sidebar = app.descendants(matching: .any).matching(identifier: "project-sidebar").firstMatch
        let actions = app.buttons["project-actions-local-plans"]
        for _ in 0..<6 where !actions.isHittable { sidebar.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(actions.isHittable)
        actions.tap()
        app.buttons["project-edit-local-plans"].tap()
        XCTAssertTrue(projectName.waitForExistence(timeout: 8))
        XCTAssertEqual(projectName.value as? String, "Local plans")
        app.navigationBars["Edit Project"].buttons["Cancel"].tap()

        app.buttons["project-sidebar-toggle"].tap()
        let switchWorkspace = app.buttons["sign-out"]
        for _ in 0..<6 where !switchWorkspace.isHittable { sidebar.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(switchWorkspace.isHittable)
        switchWorkspace.tap()
        XCTAssertTrue(local.waitForExistence(timeout: 8))
        local.tap()
        XCTAssertTrue(app.buttons["task-filter-all"].waitForExistence(timeout: 8))
        app.buttons["task-filter-all"].tap()
        XCTAssertTrue(parent.waitForExistence(timeout: 8), "Leaving the workspace must not erase it")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "waiting to sync")).firstMatch.exists)
    }

    func testSwitchingToLocalWorkspaceDiscardsRemoteAttachmentWarning() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-attachment-refresh-failure"]
        app.launch()
        defer { app.terminate() }
        let warning = app.staticTexts["attachment-refresh-status"]
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sync-refresh"].exists)

        app.buttons["project-sidebar-toggle"].tap()
        let sidebar = app.descendants(matching: .any).matching(identifier: "project-sidebar").firstMatch
        let switchWorkspace = app.buttons["sign-out"]
        for _ in 0..<6 where !switchWorkspace.isHittable { sidebar.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(switchWorkspace.isHittable)
        switchWorkspace.tap()
        let local = app.buttons["workspace.use-local"]
        XCTAssertTrue(local.waitForExistence(timeout: 8))
        local.tap()

        XCTAssertTrue(app.buttons["task-add"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["sync-refresh"].exists)
        XCTAssertTrue(warning.waitForNonExistence(timeout: 8),
                      "A local workspace must not retain a different workspace's attachment failure")
    }
}
