import OTodoCore
import SwiftUI

struct TaskBulkEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTextFocused: Bool

    private let projectSlugs: [String]
    private let tags: [String]
    private let onSave: @MainActor ([String]) async -> String?
    @State private var text = ""
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        projectSlugs: [String],
        tags: [String],
        onSave: @escaping @MainActor ([String]) async -> String?
    ) {
        self.projectSlugs = projectSlugs
        self.tags = tags
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
                if !projectSlugs.isEmpty || !tags.isEmpty {
                    Section {
                        if !projectSlugs.isEmpty {
                            LabeledContent("Projects", value: projectSlugs.joined(separator: ", "))
                        }
                        if !tags.isEmpty {
                            LabeledContent("Tags", value: tags.joined(separator: ", "))
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
                    Text("Blank lines are ignored. Put dates and times in names, like “Call mum Wed at 3 pm” or “Buy milk 18:30”. A time alone means today; names without schedule phrases stay undated.")
                }
                if !entries.isEmpty {
                    Section("Preview") {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            let name = String(entry).trimmingCharacters(in: .whitespacesAndNewlines)
                            let detected = try? DueDatePhraseDetector.detect(in: name, calendar: TaskSchedule.calendar)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(detected?.nameWithoutPhrase ?? name)
                                Text(detected.map {
                                    "\($0.dueDate.rawValue)\($0.dueTime.map { " at \($0.rawValue)" } ?? "")"
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
            .background(OTodoCanvas())
            .navigationTitle("Bulk Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
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
