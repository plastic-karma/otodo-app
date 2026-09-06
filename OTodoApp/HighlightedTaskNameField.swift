import SwiftUI
import UIKit

struct HighlightedTaskNameField: UIViewRepresentable {
    @Binding var text: String
    let highlightRange: NSRange?
    let accessibilityIdentifier: String
    @Binding var requestsFocus: Bool

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    func makeUIView(context: Context) -> NameTextField {
        let textField = NameTextField()
        textField.borderStyle = .none
        textField.placeholder = "Name"
        textField.backgroundColor = .clear
        textField.clearButtonMode = .whileEditing
        textField.autocapitalizationType = .sentences
        textField.autocorrectionType = .default
        textField.returnKeyType = .done
        textField.adjustsFontForContentSizeCategory = true
        textField.accessibilityLabel = "Todo name"
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
        textField.isEnabled = context.environment.isEnabled
        textField.wantsFocus = requestsFocus
        if requestsFocus {
            textField.setNeedsLayout()
        }
        let validHighlightRange = validatedHighlightRange
        guard textField.attributedText?.string != text
                || context.coordinator.appliedHighlightRange != validHighlightRange
        else {
            return
        }

        let selectionOffsets = textField.selectedTextRange.map { selection in
            (
                textField.offset(from: textField.beginningOfDocument, to: selection.start),
                textField.offset(from: textField.beginningOfDocument, to: selection.end)
            )
        }
        let font = UIFont.preferredFont(forTextStyle: .body)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label,
        ]
        let attributedText = NSMutableAttributedString(
            string: text,
            attributes: baseAttributes
        )
        if let validHighlightRange {
            attributedText.addAttributes(
                [
                    .backgroundColor: UIColor.systemPurple.withAlphaComponent(0.18),
                    .foregroundColor: UIColor.systemPurple,
                ],
                range: validHighlightRange
            )
        }

        textField.font = font
        textField.defaultTextAttributes = baseAttributes
        textField.attributedText = attributedText
        context.coordinator.appliedHighlightRange = validHighlightRange

        if let selectionOffsets,
           let start = textField.position(
               from: textField.beginningOfDocument,
               offset: min(selectionOffsets.0, text.utf16.count)
           ),
           let end = textField.position(
               from: textField.beginningOfDocument,
               offset: min(selectionOffsets.1, text.utf16.count)
           )
        {
            textField.selectedTextRange = textField.textRange(from: start, to: end)
        }
    }

    private var validatedHighlightRange: NSRange? {
        guard let highlightRange,
              highlightRange.location != NSNotFound,
              highlightRange.location >= 0,
              highlightRange.length >= 0,
              NSMaxRange(highlightRange) <= text.utf16.count
        else {
            return nil
        }
        return highlightRange
    }

    @MainActor
    final class NameTextField: UITextField {
        var wantsFocus = false
        var didFulfillFocusRequest: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if wantsFocus { setNeedsLayout() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Form cells can be re-enabled or moved on screen without another window attachment.
            guard wantsFocus, isEnabled, window != nil else { return }
            guard isFirstResponder || becomeFirstResponder() else { return }
            wantsFocus = false
            // Report fulfillment after UIKit finishes layout; later user focus changes are independent.
            DispatchQueue.main.async { [weak self] in
                self?.didFulfillFocusRequest?()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: HighlightedTaskNameField
        var appliedHighlightRange: NSRange?

        init(parent: HighlightedTaskNameField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}
