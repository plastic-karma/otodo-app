import SwiftUI
import UIKit

struct HighlightedTaskNameField: UIViewRepresentable {
    @Binding var text: String
    let highlightRanges: [NSRange]
    let accessibilityIdentifier: String
    @Binding var requestsFocus: Bool
    @Binding var selection: NSRange
    @Binding var isFocused: Bool
    @Binding var isComposing: Bool

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    func makeUIView(context: Context) -> NameTextField {
        _ = EditorTouchDiagnostics.installed
        let textField = NameTextField()
        textField.borderStyle = .none
        textField.placeholder = "Todo name"
        textField.backgroundColor = .clear
        textField.textColor = .label
        textField.clearButtonMode = .whileEditing
        textField.autocapitalizationType = .sentences
        textField.autocorrectionType = .default
        textField.returnKeyType = .done
        textField.adjustsFontForContentSizeCategory = true
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.accessibilityLabel = "Todo name"
        textField.accessibilityHint = "Use a hashtag for an existing project and an at sign for an existing tag."
        textField.accessibilityIdentifier = accessibilityIdentifier
        textField.delegate = context.coordinator
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        textField.didFulfillFocusRequest = { [weak coordinator = context.coordinator] in
            coordinator?.parent.requestsFocus = false
        }
        return textField
    }

    @MainActor
    func updateUIView(_ textField: NameTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        textField.isEnabled = context.environment.isEnabled
        textField.wantsFocus = requestsFocus
        if requestsFocus || !textField.highlightRanges.isEmpty {
            textField.setNeedsLayout()
        }
        // Leave the IME's marked text and selection entirely under UIKit's control.
        guard textField.markedTextRange == nil else { return }

        textField.highlightRanges = validatedHighlightRanges
        let font = context.coordinator.nameFont(for: textField.traitCollection)
        if textField.font != font { textField.font = font }
        if textField.text != text { textField.text = text }

        // Never restore a selection while another editor owns the keyboard.
        // The binding also carries the new caret when a completion changes the text.
        if textField.isFirstResponder,
           context.coordinator.selection(in: textField) != selection,
           Range(selection, in: text) != nil,
           let start = textField.position(from: textField.beginningOfDocument, offset: selection.location),
           let end = textField.position(from: start, offset: selection.length)
        {
            textField.selectedTextRange = textField.textRange(from: start, to: end)
        }
    }

    private var validatedHighlightRanges: [NSRange] {
        let length = text.utf16.count
        return highlightRanges.filter {
            $0.location != NSNotFound && $0.location >= 0 && $0.length >= 0
                && $0.location <= length && $0.length <= length - $0.location
        }
    }

    @MainActor
    final class NameTextField: UITextField {
        var wantsFocus = false
        var didFulfillFocusRequest: (() -> Void)?
        var highlightRanges: [NSRange] = [] {
            didSet {
                if oldValue != highlightRanges { setNeedsLayout() }
            }
        }
        private var decorationLayer: CAShapeLayer?
        private var decorationTraits: UITraitCollection?
        private static let decorationColor = UIColor.systemPurple.withAlphaComponent(0.18)

        func traceEditorFocus(_ event: String) {
            var ancestors: [String] = []
            var current: UIView? = self
            while let view = current {
                ancestors.append("\(type(of: view)) frame=\(view.frame) presentation=\(String(describing: view.layer.presentation()?.frame)) alpha=\(view.alpha) hidden=\(view.isHidden) interactive=\(view.isUserInteractionEnabled)")
                current = view.superview
            }
            let gestures = (gestureRecognizers ?? []).map {
                "\(type(of: $0)) enabled=\($0.isEnabled) state=\($0.state.rawValue) cancels=\($0.cancelsTouchesInView)"
            }
            NSLog("EDITOR_FOCUS %@", "\(accessibilityIdentifier ?? "unnamed") \(ObjectIdentifier(self)) \(event) first=\(isFirstResponder) requested=\(wantsFocus) enabled=\(isEnabled) animations=\(UIView.areAnimationsEnabled) gestures=\(gestures) ancestors=\(ancestors)")
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let result = super.hitTest(point, with: event)
            traceEditorFocus("hit point=\(point) result=\(String(describing: result))")
            return result
        }

        override func becomeFirstResponder() -> Bool {
            traceEditorFocus("become begin")
            let result = super.becomeFirstResponder()
            traceEditorFocus("become end result=\(result)")
            return result
        }

        override func resignFirstResponder() -> Bool {
            traceEditorFocus("resign begin stack=\(Thread.callStackSymbols.prefix(18))")
            let result = super.resignFirstResponder()
            traceEditorFocus("resign end result=\(result)")
            return result
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            traceEditorFocus("moved window")
            if wantsFocus { setNeedsLayout() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            defer { layoutHighlights() }
            // Form cells can be re-enabled or moved on screen without another window attachment.
            guard wantsFocus, isEnabled, window != nil else { return }
            traceEditorFocus("requested layout")
            guard isFirstResponder || becomeFirstResponder() else { return }
            wantsFocus = false
            // Report fulfillment after UIKit finishes layout; later user focus changes are independent.
            DispatchQueue.main.async { [weak self] in
                self?.didFulfillFocusRequest?()
            }
        }

        private func layoutHighlights() {
            guard !highlightRanges.isEmpty, markedTextRange == nil else {
                decorationLayer?.path = nil
                return
            }
            if decorationLayer == nil {
                let decoration = CAShapeLayer()
                decoration.actions = [
                    "path": NSNull(), "fillColor": NSNull(),
                    "bounds": NSNull(), "position": NSNull(),
                ]
                layer.insertSublayer(decoration, at: 0)
                decorationLayer = decoration
            }
            guard let decorationLayer else { return }
            if traitCollection.hasDifferentColorAppearance(comparedTo: decorationTraits) {
                decorationLayer.fillColor = Self.decorationColor.resolvedColor(with: traitCollection).cgColor
                decorationTraits = traitCollection
            }
            // Decoration never rewrites text storage, typing attributes, or the native caret.
            let path = CGMutablePath()
            let clip = editingRect(forBounds: bounds)
            func append(_ rect: CGRect) {
                let visible = convert(rect, from: textInputView).intersection(clip)
                if !visible.isNull, !visible.isEmpty { path.addRect(visible) }
            }
            for range in highlightRanges {
                guard let start = position(from: beginningOfDocument, offset: range.location),
                      let end = position(from: start, offset: range.length),
                      let textRange = textRange(from: start, to: end)
                else { continue }
                let rectangles = selectionRects(for: textRange)
                if rectangles.isEmpty {
                    append(firstRect(for: textRange))
                } else {
                    for rectangle in rectangles { append(rectangle.rect) }
                }
            }
            decorationLayer.frame = bounds
            decorationLayer.path = path
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: HighlightedTaskNameField
        var isUpdating = false
        private var preferredNameFont: UIFont?
        private var roundedNameFont: UIFont?

        init(parent: HighlightedTaskNameField) {
            self.parent = parent
        }

        func nameFont(for traits: UITraitCollection) -> UIFont {
            let preferred = UIFont.preferredFont(forTextStyle: .title2, compatibleWith: traits)
            if preferredNameFont == preferred, let roundedNameFont {
                return roundedNameFont
            }
            let descriptor = preferred.fontDescriptor.withDesign(.rounded) ?? preferred.fontDescriptor
            let rounded = UIFont(descriptor: descriptor, size: preferred.pointSize)
            preferredNameFont = preferred
            roundedNameFont = rounded
            return rounded
        }

        @objc func textDidChange(_ textField: UITextField) {
            reportEditingState(textField)
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            reportEditingState(textField)
        }

        func selection(in textField: UITextField) -> NSRange? {
            guard let range = textField.selectedTextRange else { return nil }
            return NSRange(
                location: textField.offset(from: textField.beginningOfDocument, to: range.start),
                length: textField.offset(from: range.start, to: range.end)
            )
        }

        private func reportEditingState(_ textField: UITextField) {
            guard !isUpdating else { return }
            let text = textField.text ?? ""
            if parent.text != text { parent.text = text }
            if let selection = selection(in: textField), parent.selection != selection {
                parent.selection = selection
            }
            let composing = textField.markedTextRange != nil
            if parent.isComposing != composing { parent.isComposing = composing }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
            reportEditingState(textField)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            // A user-initiated focus change cancels any deferred layout request.
            (textField as? NameTextField)?.wantsFocus = false
            parent.requestsFocus = false
            if parent.isFocused { parent.isFocused = false }
            reportEditingState(textField)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}
