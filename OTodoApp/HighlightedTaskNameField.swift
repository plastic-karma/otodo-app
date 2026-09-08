import SwiftUI
import UIKit

struct HighlightedTaskNameField: UIViewRepresentable {
    @Binding var text: String
    let highlightRanges: [NSRange]
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
        textField.isEnabled = context.environment.isEnabled
        textField.wantsFocus = requestsFocus
        if requestsFocus {
            textField.setNeedsLayout()
        }
        let validHighlightRanges = validatedHighlightRanges
        let font = context.coordinator.nameFont(for: textField.traitCollection)
        guard textField.attributedText?.string != text
                || context.coordinator.appliedHighlightRanges != validHighlightRanges
                || textField.font != font
        else {
            return
        }

        // An unfocused name field must not restore its UIKit selection while another
        // editor owns the keyboard (for example when moving directly into notes).
        let selectionOffsets = (textField.isFirstResponder ? textField.selectedTextRange : nil).map { selection in
            (
                textField.offset(from: textField.beginningOfDocument, to: selection.start),
                textField.offset(from: textField.beginningOfDocument, to: selection.end)
            )
        }
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
            parent.text = textField.text ?? ""
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            // A user-initiated focus change cancels any deferred layout request.
            (textField as? NameTextField)?.wantsFocus = false
            parent.requestsFocus = false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}
