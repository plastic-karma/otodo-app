import Foundation
import XCTest

@MainActor
final class ProjectArchiveUITests: XCTestCase {
    private let seedID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    private let overdueID = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
    private let futureID = "01ARZ3NDEKTSV4RRFFQ69G5FAX"
    private let completedID = "01ARZ3NDEKTSV4RRFFQ69G5FAZ"

    func testDefaultArchiveRetainsEditableTasksAndRestoresAcrossOfflineRelaunch() {
        continueAfterFailure = false
        let app = launchWorkspace()
        defer { app.terminate() }
        var originalLabels: [String: String] = [:]
        for id in [seedID, overdueID, completedID] {
            originalLabels[id] = taskRow(id, in: app).label
        }

        openArchive("home", in: app)
        capture("Archive project · explicit leave defaults", in: app)
        app.navigationBars["Archive Project"].buttons["Cancel"].tap()
        XCTAssertTrue(archiveEditor(in: app).waitForNonExistence(timeout: 8))
        openSidebar(in: app)
        XCTAssertFalse(app.buttons["sidebar-archived-projects"].exists,
                       "Opening and cancelling archive must not change the project")
        openArchive("home", in: app)
        saveArchive(in: app)

        for (id, label) in originalLabels {
            XCTAssertEqual(taskRow(id, in: app).label, label,
                           "Default archive must leave open and finished task metadata unchanged")
        }
        openArchivedProjects(in: app)
        revealSidebarControl(app.buttons["project-filter-home"], in: app)
        capture("Archived projects · retained work remains accessible", in: app)

        relaunchOffline(app)
        for (id, label) in originalLabels {
            XCTAssertEqual(taskRow(id, in: app).label, label)
        }
        let row = taskRow(seedID, in: app)
        row.tap()
        let notes = app.textViews["task-editor-notes"]
        app.revealTaskEditorElement(notes)
        notes.tap()
        notes.typeText("Continue this task without losing its archived project.")
        let keyboardDone = app.buttons["task-editor-keyboard-done"]
        if app.keyboards.firstMatch.exists {
            XCTAssertTrue(keyboardDone.waitForExistence(timeout: 8))
            keyboardDone.tap()
        }
        let save = app.buttons["task-editor-save"]
        XCTAssertTrue(save.isEnabled, "An archived membership must remain valid in the task editor")
        capture("Archived project · retained task remains editable", in: app)
        save.tap()
        XCTAssertTrue(app.textFields["task-editor-name"].waitForNonExistence(timeout: 8))
        XCTAssertTrue(taskRow(seedID, in: app).label.contains("Projects: home"))

        openArchivedProjects(in: app)
        let actions = app.buttons["project-actions-home"]
        revealSidebarControl(actions, in: app)
        actions.tap()
        let restore = app.buttons["project-restore-home"]
        XCTAssertTrue(restore.waitForExistence(timeout: 8))
        restore.tap()
        XCTAssertTrue(app.buttons["sidebar-archived-projects"].waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.buttons["project-filter-home"].exists)

        relaunchOffline(app)
        openSidebar(in: app)
        XCTAssertFalse(app.buttons["sidebar-archived-projects"].exists)
        XCTAssertTrue(app.buttons["project-filter-home"].exists)
        closeSidebar(in: app)
        taskRow(seedID, in: app).tap()
        app.revealTaskEditorElement(notes)
        XCTAssertEqual(notes.value as? String, "Continue this task without losing its archived project.")
    }

    func testArchiveMovesToInboxAndCompletesOnlyOpenProjectTasks() {
        continueAfterFailure = false
        let app = launchWorkspace()
        defer { app.terminate() }
        let unaffected = taskRow(futureID, in: app).label

        openArchive("home", in: app)
        chooseDestination("Move to Inbox", in: app)
        let complete = app.switches["project-archive-complete-open"]
        revealArchiveControl(complete, in: app)
        complete.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(complete.value as? String, "1", "Completion must be explicitly enabled before archiving")
        capture("Archive project · Inbox and explicit completion", in: app)
        saveArchive(in: app)
        relaunchOffline(app)

        for id in [seedID, overdueID, completedID] {
            let row = taskRow(id, in: app)
            XCTAssertTrue(row.label.contains("State: Done"), row.label)
            XCTAssertFalse(row.label.contains("Projects:"), "Inbox disposition must remove project links")
            XCTAssertTrue(row.label.contains("Tags: home"), "Archiving must preserve unrelated tags")
        }
        XCTAssertEqual(taskRow(futureID, in: app).label, unaffected,
                       "Completing one project must not change another project's work")
        openArchivedProjects(in: app)
        XCTAssertTrue(app.buttons["project-filter-home"].exists)
    }

    func testArchiveMovesToNewThenExistingProjectWhileOffline() {
        continueAfterFailure = false
        let app = launchWorkspace()
        defer { app.terminate() }

        openArchive("home", in: app)
        chooseDestination("Move to project", in: app)
        let name = app.textFields["project-archive-new-name"]
        revealArchiveControl(name, in: app)
        name.tap()
        name.typeText("Follow Up")
        capture("Archive project · create destination atomically", in: app)
        saveArchive(in: app)
        XCTAssertTrue(taskRow(seedID, in: app).label.contains("Projects: follow-up"))
        XCTAssertTrue(taskRow(seedID, in: app).label.contains("State: Pending"))

        openArchive("follow-up", in: app)
        chooseDestination("Move to project", in: app)
        let target = app.buttons["project-archive-target"]
        revealArchiveControl(target, in: app)
        target.tap()
        let work = app.buttons["Work"].firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 8))
        work.tap()
        capture("Archive project · existing destination", in: app)
        saveArchive(in: app)
        relaunchOffline(app)

        for id in [seedID, overdueID, completedID] {
            let row = taskRow(id, in: app)
            XCTAssertTrue(row.label.contains("Projects: work"), row.label)
            XCTAssertTrue(row.label.contains(id == completedID ? "State: Done" : "State: Pending"))
        }
        openArchivedProjects(in: app)
        revealSidebarControl(app.buttons["project-filter-follow-up"], in: app)
        XCTAssertTrue(app.buttons["project-filter-home"].exists)
        XCTAssertTrue(app.buttons["project-filter-follow-up"].exists)
        capture("Archived projects · consecutive offline moves", in: app)
    }

    private func launchWorkspace() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-light"]
        app.launch()
        XCTAssertTrue(app.buttons["task-filter-all"].waitForExistence(timeout: 10))
        app.buttons["task-filter-all"].tap()
        return app
    }

    private func relaunchOffline(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments = ["-ui-testing", "-ui-testing-light"]
        app.launch()
        XCTAssertTrue(app.buttons["task-filter-all"].waitForExistence(timeout: 10))
        app.buttons["task-filter-all"].tap()
    }

    private func openSidebar(in app: XCUIApplication) {
        if !app.buttons["project-sidebar-close"].exists {
            app.buttons["project-sidebar-toggle"].tap()
        }
        XCTAssertTrue(app.buttons["project-sidebar-close"].waitForExistence(timeout: 8))
    }

    private func closeSidebar(in app: XCUIApplication) {
        app.buttons["project-sidebar-close"].tap()
        XCTAssertTrue(app.buttons["project-sidebar-close"].waitForNonExistence(timeout: 8))
    }

    private func openArchivedProjects(in app: XCUIApplication) {
        openSidebar(in: app)
        let archived = app.buttons["sidebar-archived-projects"]
        XCTAssertTrue(archived.waitForExistence(timeout: 8))
        revealSidebarControl(archived, in: app)
        if archived.value as? String != "Expanded" { archived.tap() }
    }

    private func openArchive(_ slug: String, in app: XCUIApplication) {
        openSidebar(in: app)
        let actions = app.buttons["project-actions-\(slug)"]
        revealSidebarControl(actions, in: app)
        actions.tap()
        let archive = app.buttons["project-archive-\(slug)"]
        XCTAssertTrue(archive.waitForExistence(timeout: 8))
        archive.tap()
        XCTAssertTrue(app.buttons["project-archive-destination"].waitForExistence(timeout: 8))
    }

    private func chooseDestination(_ title: String, in app: XCUIApplication) {
        let picker = app.buttons["project-archive-destination"]
        revealArchiveControl(picker, in: app)
        picker.tap()
        let choice = app.buttons[title].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 8))
        choice.tap()
    }

    private func saveArchive(in app: XCUIApplication) {
        let save = app.buttons["project-archive-save"]
        XCTAssertTrue(save.isEnabled, "The selected archive disposition must be valid")
        save.tap()
        XCTAssertTrue(archiveEditor(in: app).waitForNonExistence(timeout: 8),
                      "Archiving must save the complete operation before dismissing")
    }

    private func archiveEditor(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "project-archive-editor").firstMatch
    }

    private func revealArchiveControl(_ control: XCUIElement, in app: XCUIApplication) {
        let form = archiveEditor(in: app)
        for _ in 0..<5 where !control.isHittable { form.swipeUp() }
        for _ in 0..<5 where !control.isHittable { form.swipeDown() }
        XCTAssertTrue(control.isHittable, "Archive control must be visible and reachable")
    }

    private func revealSidebarControl(_ control: XCUIElement, in app: XCUIApplication) {
        let sidebar = app.descendants(matching: .any).matching(identifier: "project-sidebar").firstMatch
        let scroll = sidebar.scrollViews.firstMatch
        for _ in 0..<5 where !control.isHittable { scroll.swipeUp() }
        for _ in 0..<5 where !control.isHittable { scroll.swipeDown() }
        XCTAssertTrue(control.isHittable, "Project action must be reachable in the sidebar")
    }

    private func taskRow(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let row = app.buttons["task-row-\(id)"]
        let list = app.descendants(matching: .any).matching(identifier: "task-list").firstMatch
        for _ in 0..<5 where !row.isHittable { list.swipeUp() }
        for _ in 0..<5 where !row.isHittable { list.swipeDown() }
        XCTAssertTrue(row.isHittable, "The requested task must remain available")
        return row
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
