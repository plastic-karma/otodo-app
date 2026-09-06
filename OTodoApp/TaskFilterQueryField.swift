import SwiftUI
import UIKit

/// UITextView supplies real UTF-16 selections on iOS 17, including selections made in existing queries.
struct TaskFilterQueryField: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var isFocused: Bool
    @Binding var isComposing: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.textColor = .label
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 17, weight: .regular)
        )
        view.adjustsFontForContentSizeCategory = true
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.keyboardDismissMode = .interactive
        view.accessibilityIdentifier = "filter-editor-query"
        view.accessibilityLabel = "Filter query"
        view.accessibilityHint = "Enter a query. Type project colon or tag colon for suggestions."
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        view.isEditable = context.environment.isEnabled
        // Never replace marked text or move the IME's composition selection.
        if view.markedTextRange == nil {
            if view.text != text { view.text = text }
            if view.selectedRange != selection, Range(selection, in: text) != nil {
                view.selectedRange = selection
                view.scrollRangeToVisible(selection)
            }
        }
        if isFocused, !view.isFirstResponder, view.window != nil {
            view.becomeFirstResponder()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TaskFilterQueryField
        var isUpdating = false

        init(parent: TaskFilterQueryField) {
            self.parent = parent
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
