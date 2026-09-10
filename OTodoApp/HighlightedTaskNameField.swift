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
        let textField = NameTextField()
        textField.borderStyle = .none
        textField.placeholder = "Todo name"
        textField.backgroundColor = .clear
        textField.clearButtonMode = .whileEditing
        textField.autocapitalizationType = .sentences
        textField.autocorrectionType = .default
        textField.returnKeyType = .done
        textField.adjustsFontForContentSizeCategory = true
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        textField.isEnabled = context.environment.isEnabled
        textField.wantsFocus = requestsFocus
        if requestsFocus {
            textField.setNeedsLayout()
        }
        // Replacing attributed text also replaces the IME's marked text.
        guard textField.markedTextRange == nil else { return }

        let validHighlightRanges = validatedHighlightRanges
        let font = context.coordinator.nameFont(for: textField.traitCollection)
        if textField.attributedText?.string != text
            || context.coordinator.appliedHighlightRanges != validHighlightRanges
            || textField.font != font
        {
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.label,
            ]
            let attributedText = NSMutableAttributedString(
                string: text,
                attributes: baseAttributes
            )
            for validHighlightRange in validHighlightRanges {
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
            context.coordinator.appliedHighlightRanges = validHighlightRanges
        }

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
        var appliedHighlightRanges: [NSRange] = []
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
