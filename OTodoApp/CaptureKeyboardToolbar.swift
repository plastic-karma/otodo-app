import UIKit

/// UIKit editors need an explicit accessory to share the capture actions with SwiftUI fields.
@MainActor
final class CaptureKeyboardToolbar: UIToolbar {
    private weak var responder: UIResponder?
    private var onSave: (() -> Void)?
    private let saveItem = UIBarButtonItem(title: "Save & Add Another", style: .plain, target: nil, action: nil)
    private let doneItem = UIBarButtonItem(barButtonSystemItem: .done, target: nil, action: nil)
    private var showsSave: Bool?

    init(responder: UIResponder) {
        self.responder = responder
        super.init(frame: .zero)
        tintColor = UIColor(OTodoTheme.accent)
        saveItem.target = self
        saveItem.action = #selector(saveAnother)
        saveItem.accessibilityIdentifier = "task-editor-save-another"
        doneItem.target = self
        doneItem.action = #selector(finishEditing)
        doneItem.accessibilityIdentifier = "task-editor-keyboard-done"
        update(canSave: false, onSave: nil)
    }

    required init?(coder: NSCoder) { nil }

    func update(canSave: Bool, onSave: (() -> Void)?) {
        self.onSave = onSave
        saveItem.isEnabled = canSave
        let shouldShowSave = onSave != nil
        if showsSave != shouldShowSave {
            showsSave = shouldShowSave
            let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
            items = (shouldShowSave ? [saveItem] : []) + [spacer, doneItem]
            sizeToFit()
        }
    }

    @objc private func saveAnother() { onSave?() }
    @objc private func finishEditing() { responder?.resignFirstResponder() }
}
