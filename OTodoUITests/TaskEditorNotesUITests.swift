import Foundation
import XCTest

final class TaskEditorNotesUITests: XCTestCase {
    @MainActor
    func testMultilineMarkdownSurvivesTitleFocusChangesAndOfflineRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-workspace"]
        app.launch()
        openActive(in: app)
        app.buttons["task-add"].tap()

        let name = app.textFields["task-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText("Notes regression")
        let notes = app.textViews["task-editor-notes"]
        reveal(notes, in: app)
        notes.tap() // Move directly from the native name field, without pressing Return.
        let original = "# Plan\n\n- First step\n- **Second** step\n[Reference](https://example.com)"
        notes.typeText(original)
        XCTAssertEqual(notes.value as? String, original)
        let editor = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
        app.buttons["task-editor-save"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 8))

        app.terminate()
        app.launchArguments.removeAll { $0 == "-ui-testing-reset-workspace" }
        app.launch()
        openActive(in: app)
        openTask("Notes regression", in: app)
        XCTAssertEqual(name.value as? String, "Notes regression", "Notes must not be redirected into the title")
        reveal(notes, in: app)
        XCTAssertEqual(notes.value as? String, original)

        // Changing the title's detected-date highlight exercises native attributed-text updates.
        reveal(name, in: app, upwards: false)
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        name.typeText(" tomorrow")
        reveal(notes, in: app)
        notes.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.95)).tap()
        notes.typeText("\n\nEdited offline.")
        let edited = original + "\n\nEdited offline."
        XCTAssertEqual(notes.value as? String, edited)
        app.buttons["task-editor-save"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 8))

        app.terminate()
        app.launch()
        openActive(in: app)
        openTask("Notes regression", in: app)
        XCTAssertEqual(name.value as? String, "Notes regression")
        reveal(notes, in: app)
        XCTAssertEqual(notes.value as? String, edited, "Both creates and edits must persist the complete Markdown body")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 8))

        // Save & Create Another explicitly requests native title focus; notes must take it back.
        app.buttons["task-add"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText("First repeated capture")
        app.buttons["task-editor-save-another"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "task-editor-saved-confirmation")
            .firstMatch.waitForExistence(timeout: 8))
        name.typeText("Second repeated capture")
        reveal(notes, in: app)
        notes.tap()
        notes.typeText("Second capture\nWith notes")
        XCTAssertEqual(notes.value as? String, "Second capture\nWith notes")
        app.buttons["task-editor-save"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 8))
        app.terminate()
        app.launch()
        openActive(in: app)
        openTask("Second repeated capture", in: app)
        reveal(notes, in: app)
        XCTAssertEqual(notes.value as? String, "Second capture\nWith notes")
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
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, upwards: Bool = true) {
        let editor = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
        for _ in 0..<8 {
            if element.exists && element.isHittable { break }
            if upwards { editor.swipeUp() } else { editor.swipeDown() }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        XCTAssertTrue(element.isHittable)
    }
}
