import SwiftUI
import UIKit
import XCTest
@testable import OTodo

@MainActor
final class TaskNameFocusTests: XCTestCase {
    func testFocusRequestSurvivesDisabledLayoutWithoutStealingLaterFocus() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()

        let name = HighlightedTaskNameField.NameTextField(frame: CGRect(x: 20, y: 100, width: 240, height: 44))
        let other = UITextField(frame: CGRect(x: 20, y: 160, width: 240, height: 44))
        name.isEnabled = false
        name.wantsFocus = true
        controller.view.addSubview(name)
        controller.view.addSubview(other)
        defer {
            name.wantsFocus = false
            name.resignFirstResponder()
            other.resignFirstResponder()
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        name.setNeedsLayout()
        name.layoutIfNeeded()
        XCTAssertFalse(name.isFirstResponder, "A disabled saving field cannot receive input")

        name.isEnabled = true
        name.setNeedsLayout()
        name.layoutIfNeeded()
        XCTAssertTrue(name.isFirstResponder, "A pending request must focus the ready field without a new window attachment")

        XCTAssertTrue(other.becomeFirstResponder())
        name.setNeedsLayout()
        name.layoutIfNeeded()
        XCTAssertTrue(other.isFirstResponder, "A fulfilled request must not steal focus back from another field")
    }

    func testTypingAfterMentionKeepsHighlightConfinedToMention() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: MentionHighlightHarness())
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer {
            window.endEditing(true)
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        let field = try XCTUnwrap(nameField(in: controller.view))
        let focused = await waitForRendering { field.isFirstResponder }
        XCTAssertTrue(focused)
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        field.insertText(" report")
        let rendered = await waitForRendering {
            guard let text = field.attributedText, text.string == "Prepare @work report" else { return false }
            return (0..<text.length).allSatisfy { index in
                let background = text.attribute(.backgroundColor, at: index, effectiveRange: nil) as? UIColor
                let hasHighlight = (background?.cgColor.alpha ?? 0) > 0
                return hasHighlight == NSLocationInRange(index, NSRange(location: 8, length: 5))
            }
        }
        XCTAssertTrue(rendered, "Native typing attributes must not spread a mention highlight into surrounding prose")
    }

    private func nameField(in view: UIView) -> HighlightedTaskNameField.NameTextField? {
        if let field = view as? HighlightedTaskNameField.NameTextField { return field }
        return view.subviews.lazy.compactMap { self.nameField(in: $0) }.first
    }

    private func waitForRendering(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private struct MentionHighlightHarness: View {
    @State private var text = "Prepare @work"
    @State private var requestsFocus = true
    @State private var selection = NSRange(location: 13, length: 0)
    @State private var isFocused = false
    @State private var isComposing = false

    var body: some View {
        HighlightedTaskNameField(
            text: $text, highlightRanges: [NSRange(location: 8, length: 5)],
            accessibilityIdentifier: "mention-highlight-test", requestsFocus: $requestsFocus,
            selection: $selection, isFocused: $isFocused, isComposing: $isComposing
        )
        .frame(width: 320, height: 44)
    }
}
