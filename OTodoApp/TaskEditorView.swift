import Foundation
import OTodoCore
import SwiftUI

struct TaskEditorDraft: Equatable, Sendable {
    var name: String
    var state: String
    var projectSlugs: [String]
    var tags: [String]
    var dueDate: CivilDate?
    var body: String

    // Keeping the source value with the draft makes an edit a lossless value operation.
    // AppModel only needs the editable fields; the workspace service remains responsible
    // for carrying these non-editable fields into the updated task.
    private(set) var preservedTask: TodoTask?

    init(configuration: StoreConfiguration) {
        name = ""
        state = configuration.defaultState
        projectSlugs = []
        tags = []
        dueDate = nil
        body = ""
        preservedTask = nil
    }

    init(task: TodoTask) {
        name = task.name
        state = task.state
        projectSlugs = task.projectSlugs
        tags = task.tags
        dueDate = task.dueDate
        body = task.body
        preservedTask = task
    }

    static func parseCommaSeparated(_ value: String) -> [String] {
        value
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func parseCivilDate(_ value: String) throws -> CivilDate? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : try CivilDate(rawValue: trimmedValue)
    }
}

struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let configuration: StoreConfiguration
    private let projectChoices: [String]
    private let onSave: @MainActor (TaskEditorDraft) async -> String?

    @State private var draft: TaskEditorDraft
    @State private var projectsText: String
    @State private var tagsText: String
    @State private var dueDateText: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        draft: TaskEditorDraft,
        configuration: StoreConfiguration,
        projectChoices: [String],
        onSave: @escaping @MainActor (TaskEditorDraft) async -> String?
    ) {
        self.configuration = configuration
        self.projectChoices = projectChoices
        self.onSave = onSave
        _draft = State(initialValue: draft)
        _projectsText = State(initialValue: draft.projectSlugs.joined(separator: ", "))
        _tagsText = State(initialValue: draft.tags.joined(separator: ", "))
        _dueDateText = State(initialValue: draft.dueDate?.rawValue ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Todo") {
                    TextField("Name", text: $draft.name)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityIdentifier("task-editor-name")

                    Picker("State", selection: $draft.state) {
                        ForEach(configuration.states, id: \.id) { state in
                            Text(state.name).tag(state.id)
                        }
                    }
                    .accessibilityIdentifier("task-editor-state")
                }

                Section {
                    TextField("work, personal", text: $projectsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Projects, separated by commas")

                    if !projectChoices.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(projectChoices, id: \.self) { project in
                                    projectChoice(project)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .accessibilityLabel("Project choices")
                    }
                } header: {
                    Text("Projects")
                } footer: {
                    Text("Enter project slugs separated by commas.")
                }

                Section {
                    TextField("errands, next", text: $tagsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Tags, separated by commas")
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Enter tags without #, separated by commas.")
                }

                Section {
                    TextField("YYYY-MM-DD", text: $dueDateText)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Due date")
                } header: {
                    Text("Due date")
                } footer: {
                    Text("Leave blank for no due date. Calendar dates are saved exactly as entered.")
                }

                Section("Notes") {
                    TextEditor(text: $draft.body)
                        .frame(minHeight: 160)
                        .accessibilityLabel("Todo notes")
                }

                if let message = validationMessage ?? saveError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Cannot save. \(message)")
                    }
                }
            }
            .accessibilityIdentifier("task-editor")
            .navigationTitle(draft.preservedTask == nil ? "New Todo" : "Edit Todo")
            .navigationBarTitleDisplayMode(.inline)
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
                    .accessibilityIdentifier("task-editor-save")
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

    @ViewBuilder
    private func projectChoice(_ project: String) -> some View {
        let isSelected = TaskEditorDraft.parseCommaSeparated(projectsText).contains(project)
        Button {
            var projects = TaskEditorDraft.parseCommaSeparated(projectsText)
            if let index = projects.firstIndex(of: project) {
                projects.remove(at: index)
            } else {
                projects.append(project)
            }
            projectsText = projects.joined(separator: ", ")
        } label: {
            Label(project, systemImage: isSelected ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("\(project) project")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var validationMessage: String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "A name is required."
        }
        if draft.name.contains("\n") || draft.name.contains("\r") {
            return "The name must be a single line."
        }
        if !configuration.states.contains(where: { $0.id == draft.state }) {
            return "Choose a configured state."
        }

        let projects = TaskEditorDraft.parseCommaSeparated(projectsText)
        if Set(projects).count != projects.count {
            return "Project slugs must be unique."
        }
        if projects.contains(where: { !Self.isValidProjectSlug($0) }) {
            return "Project slugs use lowercase letters, numbers, and hyphens."
        }
        let knownProjects = Set(projectChoices)
        if projects.contains(where: { !knownProjects.contains($0) }) {
            return "Choose projects from the available project list."
        }

        let tags = TaskEditorDraft.parseCommaSeparated(tagsText)
        if Set(tags).count != tags.count {
            return "Tags must be unique."
        }
        if tags.contains(where: { !Self.isValidTag($0) }) {
            return "Tags cannot contain spaces, #, commas, or brackets."
        }

        do {
            let dueDate = try TaskEditorDraft.parseCivilDate(dueDateText)
            if draft.preservedTask?.recurrence != nil, dueDate == nil {
                return "Recurring todos require a due date."
            }
        } catch {
            return "Enter the due date as a valid YYYY-MM-DD calendar date."
        }
        return nil
    }

    private func save() {
        guard validationMessage == nil else { return }

        do {
            var value = draft
            value.projectSlugs = TaskEditorDraft.parseCommaSeparated(projectsText)
            value.tags = TaskEditorDraft.parseCommaSeparated(tagsText)
            value.dueDate = try TaskEditorDraft.parseCivilDate(dueDateText)
            isSaving = true
            saveError = nil

            Task { @MainActor in
                let errorMessage = await onSave(value)
                isSaving = false
                if let errorMessage {
                    saveError = errorMessage
                } else {
                    dismiss()
                }
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private static func isValidProjectSlug(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              Self.isLowercaseLetterOrDigit(first)
        else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy {
            Self.isLowercaseLetterOrDigit($0) || $0 == 45
        }
    }

    private static func isValidTag(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("#")
            && !value.contains(",")
            && !value.contains(where: { "[]{}".contains($0) })
            && !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func isLowercaseLetterOrDigit(_ value: UInt8) -> Bool {
        (97 ... 122).contains(value) || (48 ... 57).contains(value)
    }
}
