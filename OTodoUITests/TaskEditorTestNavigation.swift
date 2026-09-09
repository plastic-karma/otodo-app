import XCTest

extension XCUIApplication {
    /// Scroll the form's edge, not its nested notes editor or the covered keyboard area.
    @MainActor
    func revealTaskEditorElement(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func frontmost(_ query: XCUIElementQuery) -> XCUIElement {
            query.element(boundBy: max(0, query.count - 1))
        }
        let editors = descendants(matching: .any).matching(identifier: "task-editor")
        XCTAssertTrue(editors.firstMatch.waitForExistence(timeout: 8), file: file, line: line)
        let editor = frontmost(editors)
        let navigation = frontmost(navigationBars.matching(NSPredicate(
            format: "identifier IN %@", ["New Todo", "Edit Todo"]
        )))
        let footer = frontmost(buttons.matching(identifier: "task-editor-save-another"))
        let keyboard = keyboards.firstMatch
        let done = frontmost(buttons.matching(identifier: "task-editor-keyboard-done"))

        func viewport() -> CGRect {
            let top = max(editor.frame.minY, navigation.frame.maxY) + 8
            var bottom = editor.frame.maxY - 8
            if keyboard.exists {
                bottom = min(bottom, keyboard.frame.minY - 52)
                if done.exists { bottom = min(bottom, done.frame.minY - 8) }
            }
            if footer.exists { bottom = min(bottom, footer.frame.minY - 8) }
            return CGRect(x: editor.frame.minX, y: top, width: editor.frame.width, height: max(0, bottom - top))
        }
        func isUnobscured() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let visible = viewport()
            return element.frame.minY >= visible.minY && element.frame.maxY <= visible.maxY
        }
        if isUnobscured() { return }
        if keyboard.exists && done.exists && done.isHittable { done.tap() }

        for attempt in 0..<12 {
            if isUnobscured() { return }
            let visible = viewport()
            guard visible.height > 80 else { break }
            // Lazy form rows can be absent on either side of the viewport.
            let scrollUp = element.exists ? element.frame.midY > visible.midY : attempt < 6
            let high = visible.minY + visible.height * 0.2
            let low = visible.minY + visible.height * 0.8
            let origin = coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: visible.maxX - 6, dy: scrollUp ? low : high))
            let end = origin.withOffset(CGVector(dx: visible.maxX - 6, dy: scrollUp ? high : low))
            // Stop before lifting so momentum cannot skip past the visible region.
            start.press(
                forDuration: 0.05, thenDragTo: end,
                withVelocity: .slow, thenHoldForDuration: 0.2
            )
        }
        XCTAssertTrue(element.exists, "The editor must expose the requested control", file: file, line: line)
        XCTAssertTrue(isUnobscured(), "The editor control must be clear of navigation, keyboard, and save controls", file: file, line: line)
    }
}
