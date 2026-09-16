import Foundation
import OTodoCore
import SwiftUI

struct ProjectEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Mode {
        case create(existingSlugs: Set<String>, projectsDirectory: String)
        case edit(TodoProject)
    }

    private let mode: Mode
    private let saveAction: @MainActor (String, String, String) async -> String?

    @State private var name: String
    @State private var notes: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        existingSlugs: [String],
        projectsDirectory: String,
        onSave: @escaping @MainActor (String, String) async -> String?
    ) {
        mode = .create(
            existingSlugs: Set(existingSlugs),
            projectsDirectory: projectsDirectory
        )
        saveAction = { title, slug, _ in
            await onSave(title, slug)
        }
        _name = State(initialValue: "")
        _notes = State(initialValue: "")
    }

    init(
        project: TodoProject,
        onUpdate: @escaping @MainActor (String, String) async -> String?
    ) {
        mode = .edit(project)
        saveAction = { title, _, body in
            await onUpdate(title, body)
        }
        _name = State(initialValue: project.name)
        _notes = State(initialValue: project.body)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("project-editor-name")

                    LabeledContent("Slug") {
                        Text(slug.isEmpty ? "Generated from name" : slug)
                            .foregroundStyle(slug.isEmpty ? Color.secondary : Color.primary)
                            .accessibilityIdentifier("project-editor-slug")
                    }
                } header: {
                    Text("Project")
                } footer: {
                    Text(projectPathDescription)
                }

                if editedProject != nil {
                    Section {
                        TextEditor(text: $notes)
                            .frame(minHeight: 160)
                            .accessibilityLabel("Project notes")
                            .accessibilityIdentifier("project-editor-notes")
                    } header: {
                        Text("Notes")
                    } footer: {
                        Text("Markdown notes are stored in the project record.")
                    }
                }

                if let message = validationMessage ?? saveError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Cannot save. \(message)")
                    }
                }
            }
            .accessibilityIdentifier("project-editor")
            .scrollContentBackground(.hidden)
            .background(OTodoTheme.formCanvas.ignoresSafeArea())
            .navigationTitle(editedProject == nil ? "New Project" : "Edit Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(OTodoTheme.formCanvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .accessibilityIdentifier("project-editor-save")
                    .disabled(validationMessage != nil || !hasChanges || isSaving)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView("Saving")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var editedProject: TodoProject? {
        guard case let .edit(project) = mode else { return nil }
        return project
    }

    private var slug: String {
        switch mode {
        case .create:
            Self.slug(from: trimmedName)
        case let .edit(project):
            project.slug
        }
    }

    private var validationMessage: String? {
        if let message = Self.nameValidationMessage(name: name) {
            return message
        }
        guard case let .create(existingSlugs, _) = mode else { return nil }
        let generatedSlug = Self.slug(from: trimmedName)
        guard !generatedSlug.isEmpty else {
            return "Use at least one letter or number in the project name."
        }
        guard !existingSlugs.contains(generatedSlug) else {
            return "A project with the slug \(generatedSlug) already exists."
        }
        return nil
    }

    private var hasChanges: Bool {
        guard let project = editedProject else { return true }
        return trimmedName != project.name || notes != project.body
    }

    static func creationValidationMessage(name: String, existingSlugs: Set<String>) -> String? {
        if let message = nameValidationMessage(name: name) {
            return message
        }
        let slug = Self.slug(from: name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !slug.isEmpty else {
            return "Use at least one letter or number in the project name."
        }
        guard !existingSlugs.contains(slug) else {
            return "A project with the slug \(slug) already exists."
        }
        return nil
    }

    private static func nameValidationMessage(name: String) -> String? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return "Enter a project name."
        }
        guard !title.contains("\n"), !title.contains("\r") else {
            return "Use a single line for the project name."
        }
        return nil
    }

    private var projectPathDescription: String {
        switch mode {
        case let .create(_, projectsDirectory):
            guard !slug.isEmpty else {
                return "A lowercase project slug will be generated automatically."
            }
            return "Creates \(projectsDirectory)/\(slug).md in your todo store."
        case let .edit(project):
            return "Edits \(project.relativePath). The slug stays \(project.slug) so linked todos keep working."
        }
    }

    private func save() {
        guard validationMessage == nil, hasChanges else { return }
        let title = trimmedName
        let projectSlug = slug
        let projectBody = notes
        saveError = nil
        isSaving = true

        Task { @MainActor in
            let error = await saveAction(title, projectSlug, projectBody)
            isSaving = false
            if let error {
                saveError = error
            } else {
                dismiss()
            }
        }
    }

    static func slug(from name: String) -> String {
        let folded = name
            .folding(
                options: [.diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        return folded
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
