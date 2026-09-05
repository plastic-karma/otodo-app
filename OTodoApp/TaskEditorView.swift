import Foundation
import OTodoCore
import SwiftUI

struct TaskEditorDraft: Equatable, Sendable {
    var name: String
    var state: String
    var projectSlugs: [String]
    var tags: [String]
    var dueDate: CivilDate?
    var dueTime: CivilTime?
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
        dueTime = nil
        body = ""
        preservedTask = nil
    }

    init(task: TodoTask) {
        name = task.name
        state = task.state
        projectSlugs = task.projectSlugs
        tags = task.tags
        dueDate = task.dueDate
        dueTime = task.dueTime
        body = task.body
        preservedTask = task
    }

    static func parseCommaSeparated(_ value: String) -> [String] {
        value
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

}

struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let configuration: StoreConfiguration
    private let projectChoices: [String]
    private let tagChoices: [String]
    private let onSave: @MainActor (TaskEditorDraft) async -> String?

    @State private var draft: TaskEditorDraft
    @State private var projectsText: String
    @State private var tagsText: String
    @State private var hasDueDate: Bool
    @State private var hasDueTime: Bool
    @State private var dueDate: Date
    @State private var hasPendingRelativeDueDate = false
    @State private var detectedDueDatePhrase: DetectedDueDatePhrase?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var didSaveAndContinue = false
    @State private var nameFocusRequest = 0
    @State private var isNameFocused = false

    init(
        draft: TaskEditorDraft,
        configuration: StoreConfiguration,
        projectChoices: [String],
        tagChoices: [String],
        onSave: @escaping @MainActor (TaskEditorDraft) async -> String?
    ) {
        self.configuration = configuration
        self.projectChoices = projectChoices
        self.tagChoices = tagChoices
        self.onSave = onSave
        _draft = State(initialValue: draft)
        _projectsText = State(initialValue: draft.projectSlugs.joined(separator: ", "))
        _tagsText = State(initialValue: draft.tags.joined(separator: ", "))
        _hasDueDate = State(initialValue: draft.dueDate != nil)
        _hasDueTime = State(initialValue: draft.dueTime != nil)
        _dueDate = State(initialValue: TaskSchedule.date(from: draft.dueDate, time: draft.dueTime))
        _detectedDueDatePhrase = State(
            initialValue: Self.detectDueDatePhrase(in: draft.name)
        )
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section("Todo") {
                        if didSaveAndContinue {
                            Label("Todo saved. Create another.", systemImage: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(OTodoTheme.accent)
                                .accessibilityIdentifier("task-editor-saved-confirmation")
                        }

                        HighlightedTaskNameField(
                            text: $draft.name,
                            highlightRange: detectedDueDatePhrase?.utf16Range,
                            accessibilityIdentifier: "task-editor-name",
                            isFocused: $isNameFocused
                        )
                        .onChange(of: draft.name) { _, name in
                            detectedDueDatePhrase = Self.detectDueDatePhrase(in: name)
                        }

                        if let detectedDueDatePhrase {
                            let explanation =
                                "Due \(detectedDueDatePhrase.dueDate.rawValue) · “\(detectedDueDatePhrase.phrase)” will be removed when saved"
                            Label(explanation, systemImage: "calendar.badge.checkmark")
                                .font(.footnote)
                                .foregroundStyle(OTodoTheme.accent)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(explanation)
                                .accessibilityIdentifier("task-editor-detected-due-date")
                        }

                        Picker("State", selection: $draft.state) {
                            ForEach(configuration.states, id: \.id) { state in
                                Text(state.name).tag(state.id)
                            }
                        }
                        .accessibilityIdentifier("task-editor-state")
                    }
                    .id("task-editor-top")

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
                            .accessibilityIdentifier("task-editor-tags")

                        if !matchingTagChoices.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(matchingTagChoices, id: \.self) { tag in
                                        Button {
                                            completeTag(with: tag)
                                        } label: {
                                            Label(tag, systemImage: "tag.fill")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityIdentifier("tag-suggestion-\(tag)")
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                            .accessibilityLabel("Matching existing tags")
                        }
                    } header: {
                        Text("Tags")
                    } footer: {
                        Text("Type to match existing tags, or enter new tags without #, separated by commas.")
                    }

                    Section {
                        if draft.preservedTask == nil {
                            RelativeDueDateField(
                                accessibilityIdentifierPrefix: "task-editor-relative-due",
                                onPendingChange: { hasPendingRelativeDueDate = $0 },
                                onApply: { resolvedDate in
                                    dueDate = resolvedDate
                                    hasDueDate = true
                                    hasDueTime = true
                                    saveError = nil
                                }
                            )
                            .id(nameFocusRequest)
                        }

                        Toggle("Set due date", isOn: $hasDueDate)
                            .accessibilityIdentifier("task-editor-due-date-toggle")

                        if hasDueDate {
                            DatePicker(
                                "Date",
                                selection: $dueDate,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.graphical)
                            .environment(\.calendar, TaskSchedule.calendar)
                            .accessibilityIdentifier("task-editor-due-date-picker")

                            Toggle("Include time", isOn: $hasDueTime)
                                .accessibilityIdentifier("task-editor-due-time-toggle")

                            if hasDueTime {
                                DatePicker(
                                    "Time",
                                    selection: $dueDate,
                                    displayedComponents: .hourAndMinute
                                )
                                .environment(\.calendar, TaskSchedule.calendar)
                                .accessibilityIdentifier("task-editor-due-time-picker")
                            }
                        }
                    } header: {
                        Text("Due date")
                    } footer: {
                        Text(dueDateHelpText)
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
                .disabled(isSaving)
                .accessibilityIdentifier("task-editor")
                .scrollContentBackground(.hidden)
                .background(OTodoCanvas())
                .navigationTitle(draft.preservedTask == nil ? "New Todo" : "Edit Todo")
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
                        .accessibilityIdentifier("task-editor-save")
                        .disabled(isSaveDisabled)
                    }

                    if draft.preservedTask == nil {
                        ToolbarItem(placement: .bottomBar) {
                            Button("Save & Create Another") {
                                save(createAnother: true)
                            }
                            .accessibilityIdentifier("task-editor-save-another")
                            .disabled(isSaveDisabled)
                        }
                    }
                }
                .overlay {
                    if isSaving {
                        ProgressView("Saving")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .onChange(of: nameFocusRequest) { _, _ in
                    proxy.scrollTo("task-editor-top", anchor: .top)
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

    private var matchingTagChoices: [String] {
        let selected = Set(TaskEditorDraft.parseCommaSeparated(tagsText))
        let fragment = currentTagFragment
        var matches: [String] = []
        matches.reserveCapacity(min(8, tagChoices.count))

        for tag in tagChoices where !selected.contains(tag) {
            guard fragment.isEmpty
                    || tag.range(
                        of: fragment,
                        options: [.caseInsensitive, .anchored]
                    ) != nil
            else {
                continue
            }
            matches.append(tag)
            if matches.count == 8 {
                break
            }
        }
        return matches
    }

    private var currentTagFragment: String {
        let fragment = tagsText
            .split(separator: ",", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? ""
        return fragment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func completeTag(with tag: String) {
        var tags = TaskEditorDraft.parseCommaSeparated(tagsText)
        if !currentTagFragment.isEmpty, !tags.isEmpty {
            tags.removeLast()
        }
        tags.append(tag)
        tagsText = tags.joined(separator: ", ") + ", "
    }

    private var validationMessage: String? {
        let savedName = detectedDueDatePhrase?.nameWithoutPhrase ?? draft.name
        if savedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return detectedDueDatePhrase == nil
                ? "A name is required."
                : "Add a name besides the due date."
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

        if hasDueDate, selectedDueDate == nil {
            return "Choose a valid due date."
        }
        if draft.preservedTask?.recurrence != nil,
           !hasDueDate,
           detectedDueDatePhrase == nil
        {
            return "Recurring todos require a due date."
        }
        return nil
    }

    private var isSaveDisabled: Bool {
        validationMessage != nil || hasPendingRelativeDueDate || isSaving
    }

    private func save(createAnother: Bool = false) {
        guard !isSaveDisabled else { return }

        var value = draft
        value.name = detectedDueDatePhrase?.nameWithoutPhrase ?? draft.name
        value.projectSlugs = TaskEditorDraft.parseCommaSeparated(projectsText)
        value.tags = TaskEditorDraft.parseCommaSeparated(tagsText)
        value.dueDate = detectedDueDatePhrase?.dueDate ?? selectedDueDate
        value.dueTime = selectedDueTime
        isNameFocused = false
        isSaving = true
        saveError = nil
        didSaveAndContinue = false

        Task { @MainActor in
            let errorMessage = await onSave(value)
            isSaving = false
            if let errorMessage {
                saveError = errorMessage
            } else if createAnother {
                draft.name = ""
                draft.body = ""
                draft.dueDate = nil
                draft.dueTime = nil
                hasDueDate = false
                hasDueTime = false
                dueDate = TaskSchedule.date(from: nil, time: nil)
                detectedDueDatePhrase = nil
                hasPendingRelativeDueDate = false
                didSaveAndContinue = true
                nameFocusRequest += 1
                isNameFocused = true
            } else {
                dismiss()
            }
        }
    }

    private var selectedDueDate: CivilDate? {
        guard hasDueDate else { return nil }
        return TaskSchedule.civilDate(from: dueDate)
    }

    private var selectedDueTime: CivilTime? {
        guard hasDueDate, hasDueTime else { return nil }
        return TaskSchedule.civilTime(from: dueDate)
    }

    private var dueDateHelpText: String {
        if let detectedDueDatePhrase {
            return "The highlighted phrase sets \(detectedDueDatePhrase.dueDate.rawValue) when saved."
        }
        guard hasDueDate else {
            return "This todo has no due date."
        }
        if hasDueTime {
            return "Choose the calendar date and exact due time."
        }
        return "Choose a calendar date. Date-only reminders arrive at 9:00 AM."
    }

    private static func detectDueDatePhrase(in name: String) -> DetectedDueDatePhrase? {
        try? DueDatePhraseDetector.detect(
            in: name,
            calendar: TaskSchedule.calendar
        )
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
