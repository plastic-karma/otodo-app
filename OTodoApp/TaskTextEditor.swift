import SwiftUI
import UIKit

/// UITextView supplies real UTF-16 selections and marked-text state on iOS 17.
struct TaskTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var isFocused: Bool
    @Binding var isComposing: Bool
    let style: Style

    enum Style: Equatable {
        case filterQuery
        case notes
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.textColor = .label
        view.font = context.coordinator.font(for: view.traitCollection)
        view.adjustsFontForContentSizeCategory = true
        switch style {
        case .filterQuery:
            view.autocapitalizationType = .none
            view.autocorrectionType = .no
            view.smartQuotesType = .no
            view.smartDashesType = .no
            view.smartInsertDeleteType = .no
            view.textContainer.lineFragmentPadding = 0
            view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
            view.accessibilityIdentifier = "filter-editor-query"
            view.accessibilityLabel = "Filter query"
            view.accessibilityHint = "Enter a query. Type project colon or tag colon for suggestions."
        case .notes:
            view.autocapitalizationType = .sentences
            view.autocorrectionType = .default
            view.accessibilityIdentifier = "task-editor-notes"
            view.accessibilityLabel = "Todo notes"
        }
        view.keyboardDismissMode = .interactive
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        view.isEditable = context.environment.isEnabled
        let font = context.coordinator.font(for: view.traitCollection)
        // Never replace marked text or move the IME's composition selection.
        if view.markedTextRange == nil {
            if view.font != font { view.font = font }
            if view.text != text { view.text = text }
        }
        if isFocused, !view.isFirstResponder, view.window != nil {
            view.becomeFirstResponder()
        }
        // Do not restore stale selections in an inactive editor when focus changes.
        if view.isFirstResponder, view.markedTextRange == nil,
           view.selectedRange != selection, Range(selection, in: text) != nil
        {
            view.selectedRange = selection
            view.scrollRangeToVisible(selection)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TaskTextEditor
        var isUpdating = false
        private var preferredBodyFont: UIFont?
        private var editorFont: UIFont?
        private var fontStyle: Style?

        init(parent: TaskTextEditor) {
            self.parent = parent
        }

        func font(for traits: UITraitCollection) -> UIFont {
            let preferred = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
            if preferredBodyFont == preferred, fontStyle == parent.style, let editorFont {
                return editorFont
            }
            let font: UIFont
            switch parent.style {
            case .filterQuery:
                font = UIFontMetrics(forTextStyle: .body).scaledFont(
                    for: .monospacedSystemFont(ofSize: 17, weight: .regular),
                    compatibleWith: traits
                )
            case .notes:
                let descriptor = preferred.fontDescriptor.withDesign(.rounded) ?? preferred.fontDescriptor
                font = UIFont(descriptor: descriptor, size: preferred.pointSize)
            }
            preferredBodyFont = preferred
            editorFont = font
            fontStyle = parent.style
            return font
        }

        func textViewDidChange(_ textView: UITextView) {
            reportEditingState(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            reportEditingState(textView)
        }

        private func reportEditingState(_ textView: UITextView) {
            guard !isUpdating else { return }
            if parent.text != textView.text { parent.text = textView.text }
            if parent.selection != textView.selectedRange { parent.selection = textView.selectedRange }
            let composing = textView.markedTextRange != nil
            if parent.isComposing != composing { parent.isComposing = composing }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
            reportEditingState(textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
            reportEditingState(textView)
        }
    }
}
