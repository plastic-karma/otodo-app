import Foundation
import OTodoCore
import SwiftUI

struct ProjectEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let existingSlugs: Set<String>
    private let projectsDirectory: String
    private let project: TodoProject?
    private let onSave: @MainActor (String, String, String) async -> String?

    @State private var name = ""
    @State private var notes = ""
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        existingSlugs: [String],
        projectsDirectory: String,
        project: TodoProject? = nil,
        onSave: @escaping @MainActor (String, String, String) async -> String?
    ) {
        self.existingSlugs = Set(existingSlugs)
        self.projectsDirectory = projectsDirectory
        self.onSave = onSave
        self.project = project
        _name = State(initialValue: project?.name ?? "")
        _notes = State(initialValue: project?.body ?? "")
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

                Section {
                    TextEditor(text: $notes)
                        .frame(minHeight: 160)
                        .accessibilityIdentifier("project-editor-notes")
                } header: {
                    Text("Notes")
                } footer: {
                    Text("Markdown is saved in the project file.")
                }

                if let message = validationMessage ?? saveError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Cannot save. \(message)")
                    }
                }
            }
            .disabled(isSaving)
            .accessibilityIdentifier("project-editor")
            .scrollContentBackground(.hidden)
            .background(OTodoTheme.formCanvas.ignoresSafeArea())
            .navigationTitle(project == nil ? "New Project" : "Edit Project")
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
                    .disabled(validationMessage != nil || isSaving)
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

    private var slug: String {
        project?.slug ?? Self.slug(from: trimmedName)
    }

    private var validationMessage: String? {
        project == nil
            ? Self.creationValidationMessage(name: name, existingSlugs: existingSlugs)
            : Self.nameValidationMessage(trimmedName)
    }

    private static func nameValidationMessage(_ name: String) -> String? {
        guard !name.isEmpty else {
            return "Enter a project name."
        }
        guard !name.contains("\n"), !name.contains("\r") else {
            return "Use a single line for the project name."
        }
        return nil
    }

    static func creationValidationMessage(name: String, existingSlugs: Set<String>) -> String? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = nameValidationMessage(title) {
            return message
        }
        let slug = Self.slug(from: title)
        guard !slug.isEmpty else {
            return "Use at least one letter or number in the project name."
        }
        guard !existingSlugs.contains(slug) else {
            return "A project with the slug \(slug) already exists."
        }
        return nil
    }

    private var projectPathDescription: String {
        if let project {
            return "Updates \(project.relativePath). Its slug and existing todo links stay the same."
        }
        guard !slug.isEmpty else {
            return "A lowercase project slug will be generated automatically."
        }
        return "Creates \(projectsDirectory)/\(slug).md in your todo store."
    }

    private func save() {
        guard validationMessage == nil else { return }
        let title = trimmedName
        let projectSlug = slug
        let projectNotes = notes
        saveError = nil
        isSaving = true

        Task { @MainActor in
            let error = await onSave(title, projectSlug, projectNotes)
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
