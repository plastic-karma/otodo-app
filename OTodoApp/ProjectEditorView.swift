import Foundation
import SwiftUI

struct ProjectEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let existingSlugs: Set<String>
    private let projectsDirectory: String
    private let onSave: @MainActor (String, String) async -> String?

    @State private var name = ""
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        existingSlugs: [String],
        projectsDirectory: String,
        onSave: @escaping @MainActor (String, String) async -> String?
    ) {
        self.existingSlugs = Set(existingSlugs)
        self.projectsDirectory = projectsDirectory
        self.onSave = onSave
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
            .background(OTodoCanvas())
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
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
        Self.slug(from: trimmedName)
    }

    private var validationMessage: String? {
        guard !trimmedName.isEmpty else {
            return "Enter a project name."
        }
        guard !slug.isEmpty else {
            return "Use at least one letter or number in the project name."
        }
        guard !existingSlugs.contains(slug) else {
            return "A project with the slug \(slug) already exists."
        }
        return nil
    }

    private var projectPathDescription: String {
        guard !slug.isEmpty else {
            return "A lowercase project slug will be generated automatically."
        }
        return "Creates \(projectsDirectory)/\(slug).md in your todo store."
    }

    private func save() {
        guard validationMessage == nil else { return }
        let title = trimmedName
        let projectSlug = slug
        saveError = nil
        isSaving = true

        Task { @MainActor in
            let error = await onSave(title, projectSlug)
            isSaving = false
            if let error {
                saveError = error
            } else {
                dismiss()
            }
        }
    }

    private static func slug(from name: String) -> String {
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
