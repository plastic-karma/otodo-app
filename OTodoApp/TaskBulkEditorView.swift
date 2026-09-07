import OTodoCore
import SwiftUI

struct TaskBulkEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTextFocused: Bool

    private let projectSlugs: [String]
    private let tags: [String]
    private let defaultDueDate: CivilDate?
    private let onSave: @MainActor ([String]) async -> String?
    @State private var text = ""
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        projectSlugs: [String],
        tags: [String],
        defaultDueDate: CivilDate? = nil,
        onSave: @escaping @MainActor ([String]) async -> String?
    ) {
        self.projectSlugs = projectSlugs
        self.tags = tags
        self.defaultDueDate = defaultDueDate
        self.onSave = onSave
    }

    var body: some View {
        let entries = text.split(whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy(\.isWhitespace) }

        NavigationStack {
            Form {
                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("task-bulk-error")
                    }
                }
                if !projectSlugs.isEmpty || !tags.isEmpty || defaultDueDate != nil {
                    Section {
                        if !projectSlugs.isEmpty {
                            LabeledContent("Projects", value: projectSlugs.joined(separator: ", "))
                        }
                        if !tags.isEmpty {
                            LabeledContent("Tags", value: tags.joined(separator: ", "))
                        }
                        if let defaultDueDate {
                            LabeledContent("Default due date", value: defaultDueDate.rawValue)
                        }
                    } header: {
                        Text("From this view")
                    } footer: {
                        Text("Applied to every todo in this batch.")
                    }
                }


                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 280)
                        .autocorrectionDisabled()
                        .focused($isTextFocused)
                        .accessibilityLabel("Todos, one per line")
                        .accessibilityIdentifier("task-bulk-text")
                        .disabled(isSaving)
                } header: {
                    Text("One todo per line")
                } footer: {
                    Text("Blank lines are ignored. Put dates and times in names, like “Call mum Wed at 3 pm” or “Buy milk 18:30”. A time alone means today. Other names use this view’s default date, when present.")
                }
                if !entries.isEmpty {
                    Section("Preview") {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            let name = String(entry).trimmingCharacters(in: .whitespacesAndNewlines)
                            let detected = try? DueDatePhraseDetector.detect(in: name, calendar: TaskSchedule.calendar)
                            let date = detected?.resolvedDueDate(selectedDate: defaultDueDate) ?? defaultDueDate
                            VStack(alignment: .leading, spacing: 4) {
                                Text(detected?.nameWithoutPhrase ?? name)
                                Text(date.map {
                                    "\($0.rawValue)\(detected?.dueTime.map { " at \($0.rawValue)" } ?? "")"
                                } ?? "No due date")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("task-bulk-preview-\(index)")
                        }
                    }
                }
            }
            .accessibilityIdentifier("task-bulk-editor")
            .scrollContentBackground(.hidden)
            .background(OTodoTheme.formCanvas.ignoresSafeArea())
            .navigationTitle("Bulk Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(OTodoTheme.formCanvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create \(entries.count)") {
                        save(names: entries.map(String.init))
                    }
                    .accessibilityIdentifier("task-bulk-save")
                    .disabled(entries.isEmpty || isSaving)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView("Saving todos")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .task { isTextFocused = true }
        }
    }

    private func save(names: [String]) {
        guard !isSaving, !names.isEmpty else { return }
        isSaving = true
        saveError = nil
        Task { @MainActor in
            saveError = await onSave(names)
            isSaving = false
            if saveError == nil {
                dismiss()
            }
        }
    }
}
