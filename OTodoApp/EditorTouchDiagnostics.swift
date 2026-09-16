import ObjectiveC
import UIKit

// Diagnostic branch only; this probe is not part of the delivery ref.
@MainActor
enum EditorTouchDiagnostics {
    static let installed: Void = {
        guard let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
              let traced = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.editor_traceSendEvent(_:)))
        else { preconditionFailure("Missing native window event entry point") }
        method_exchangeImplementations(original, traced)
    }()
}

extension UIWindow {
    @objc fileprivate dynamic func editor_traceSendEvent(_ event: UIEvent) {
        if let touches = event.allTouches {
            for touch in touches where touch.phase == .began || touch.phase == .ended {
                editor_trace(touch, stage: "before")
            }
        }
        editor_traceSendEvent(event)
        if let touches = event.allTouches {
            for touch in touches where touch.phase == .ended {
                editor_trace(touch, stage: "after")
            }
        }
    }

    private func editor_trace(_ touch: UITouch, stage: String) {
        NSLog("EDITOR_TOUCH %@", "\(stage) phase=\(touch.phase.rawValue) point=\(touch.location(in: self)) window=\(ObjectIdentifier(self))")
        var ancestor = touch.view
        var depth = 0
        while let view = ancestor, depth < 12 {
            let switchState = (view as? UISwitch).map { " on=\($0.isOn) enabled=\($0.isEnabled)" } ?? ""
            NSLog("EDITOR_TOUCH %@", "depth=\(depth) \(type(of: view)) \(ObjectIdentifier(view)) id=\(view.accessibilityIdentifier ?? "nil") screen=\(view.convert(view.bounds, to: self)) model=\(view.frame) presentation=\(String(describing: view.layer.presentation()?.frame)) alpha=\(view.alpha) hidden=\(view.isHidden) interactive=\(view.isUserInteractionEnabled)\(switchState)")
            ancestor = view.superview
            depth += 1
        }
    }
}
