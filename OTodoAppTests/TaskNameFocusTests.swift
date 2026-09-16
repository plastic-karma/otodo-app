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

    func testRetainedFieldCannotStealKeyboardFromItsVisibleReplacement() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()

        let frame = CGRect(x: 20, y: 100, width: 240, height: 44)
        let retained = HighlightedTaskNameField.NameTextField(frame: frame)
        let visible = HighlightedTaskNameField.NameTextField(frame: frame)
        controller.view.addSubview(retained)
        controller.view.addSubview(visible)
        defer {
            retained.wantsFocus = false
            retained.resignFirstResponder()
            visible.resignFirstResponder()
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        XCTAssertTrue(visible.becomeFirstResponder())
        retained.wantsFocus = true
        retained.setNeedsLayout()
        retained.layoutIfNeeded()
        XCTAssertTrue(visible.isFirstResponder, "A retained cell must not take the live input's keyboard")

        visible.removeFromSuperview()
        retained.setNeedsLayout()
        retained.layoutIfNeeded()
        XCTAssertTrue(retained.isFirstResponder, "The request remains pending until its field is interactive")
    }
}
