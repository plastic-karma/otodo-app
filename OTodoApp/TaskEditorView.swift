import Foundation
import OTodoCore
import SwiftUI
import UIKit

struct TaskEditorDraft: Equatable, Sendable {
    var name: String
    var state: String
    var projectSlugs: [String]
    var tags: [String]
    var parentID: TaskID?
    var dueDate: CivilDate?
    var dueTime: CivilTime?
    var recurrence: String?
    var recurrenceFrom: RecurrenceFrom?
    var body: String
    var url: String?
    var subtaskNames: [String] = []
    var attachments: [AttachmentDraft] = []
    var removingAttachmentPaths: [String] = []

    // Keeping the source value with the draft makes an edit a lossless value operation.
    // AppModel only needs the editable fields; the workspace service remains responsible
    // for carrying these non-editable fields into the updated task.
    private(set) var preservedTask: TodoTask?

    init(configuration: StoreConfiguration) {
        name = ""
        state = configuration.defaultState
        projectSlugs = []
        tags = []
        parentID = nil
        dueDate = nil
        dueTime = nil
        recurrence = nil
        recurrenceFrom = nil
        body = ""
        url = nil
        preservedTask = nil
    }

    init(task: TodoTask) {
        name = task.name
        state = task.state
        projectSlugs = task.projectSlugs
        tags = task.tags
        parentID = task.parentID
        dueDate = task.dueDate
        dueTime = task.dueTime
        recurrence = task.recurrence
        recurrenceFrom = task.recurrenceFrom
        body = task.body
        url = task.url
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let attachmentModel: AppModel?
    private let attachmentSelection: RepositorySelection?
    private let configuration: StoreConfiguration
    private let projectChoices: [String]
    private let tagChoices: [String]
    private let hierarchy: TaskHierarchy
    private let workspaceTasks: [TodoTask]
    private let onSave: @MainActor (TaskEditorDraft) async -> String?
    private let defaultsToToday: Bool

    @State private var draft: TaskEditorDraft
    @State private var projectsText: String
    @State private var tagsText: String
    @State private var hasDueDate: Bool
    @State private var hasDueTime: Bool
    @State private var dueDate: Date
    @State private var hasPendingRelativeDueDate = false
    @State private var detectedDueDatePhrase: DetectedDueDatePhrase?
    @State private var recurrenceError: String?
    @State private var recurrenceRule: RecurrenceRule?
    @State private var initialRecurrenceSettings: TaskRecurrenceFields.Settings
    @State private var isEditorPresented = true
    @State private var isImportingAttachments = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var didSaveAndContinue = false
    @State private var nameFocusRequest = 0
    @State private var requestsNameFocus = false
    @State private var isParentPickerPresented = false
    @State private var hasPendingSubtask = false
    @FocusState private var notesFocused: Bool
    @State private var isScheduleExpanded = false
    @State private var isDetailsExpanded = false

    init(
        draft: TaskEditorDraft,
        configuration: StoreConfiguration,
        projectChoices: [String],
        tagChoices: [String],
        hierarchy: TaskHierarchy = TaskHierarchy(tasks: []),
        workspaceTasks: [TodoTask] = [],
        attachmentModel: AppModel? = nil,
        defaultsToToday: Bool = false,
        onSave: @escaping @MainActor (TaskEditorDraft) async -> String?
    ) {
        self.attachmentModel = attachmentModel
        self.attachmentSelection = attachmentModel?.workspaceSelection
        self.configuration = configuration
        self.projectChoices = projectChoices
        self.tagChoices = tagChoices
        self.hierarchy = hierarchy
        self.workspaceTasks = workspaceTasks
        self.onSave = onSave
        self.defaultsToToday = defaultsToToday
        _draft = State(initialValue: draft)
        _projectsText = State(initialValue: draft.projectSlugs.joined(separator: ", "))
        _tagsText = State(initialValue: draft.tags.joined(separator: ", "))
        _hasDueDate = State(initialValue: draft.dueDate != nil)
        _hasDueTime = State(initialValue: draft.dueTime != nil)
        _dueDate = State(initialValue: TaskSchedule.date(from: draft.dueDate, time: draft.dueTime))
        _detectedDueDatePhrase = State(
            initialValue: Self.detectDueDatePhrase(in: draft.name)
        )
        var parsedRule: RecurrenceRule?
        var recurrenceError: String?
        do {
            parsedRule = try draft.recurrence.map { try RecurrenceRule(parsing: $0) }
        } catch {
            recurrenceError = error.localizedDescription
        }
        _recurrenceRule = State(initialValue: parsedRule)
        _recurrenceError = State(initialValue: recurrenceError)
        _initialRecurrenceSettings = State(initialValue: .init(rule: parsedRule, anchor: draft.recurrenceFrom))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        if didSaveAndContinue {
                            Label("Todo saved. Create another.", systemImage: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(OTodoTheme.accent)
                                .accessibilityIdentifier("task-editor-saved-confirmation")
                        }

                        HighlightedTaskNameField(
                            text: $draft.name,
                            highlightRanges: detectedDueDatePhrase?.utf16Ranges ?? [],
                            accessibilityIdentifier: "task-editor-name",
                            requestsFocus: $requestsNameFocus
                        )
                        .frame(minHeight: 44)
                        .onChange(of: draft.name) { _, name in
                            detectedDueDatePhrase = Self.detectDueDatePhrase(in: name)
                        }

                        if let detectedDueDatePhrase {
                            let explanation =
                                "Due \(resolvedDueDate?.rawValue ?? detectedDueDatePhrase.dueDate.rawValue)\(resolvedDueTime.map { " at \($0.rawValue)" } ?? "") · “\(detectedDueDatePhrase.phrases.joined(separator: "” and “"))” will be removed when saved"
                            Label(explanation, systemImage: "calendar.badge.checkmark")
                                .font(.footnote)
                                .foregroundStyle(OTodoTheme.accent)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(explanation)
                                .accessibilityIdentifier("task-editor-detected-due-date")
                        }

                        ZStack(alignment: .topLeading) {
                            if draft.body.isEmpty {
                                Text("Add notes…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                            TextEditor(text: $draft.body)
                                .frame(minHeight: 120)
                                .scrollContentBackground(.hidden)
                                .accessibilityLabel("Todo notes")
                                .accessibilityIdentifier("task-editor-notes")
                                .focused($notesFocused)
                                .onChange(of: notesFocused) { _, focused in
                                    if focused { requestsNameFocus = false }
                                }
                        }
                        .listRowSeparator(.hidden)
                    }
                    .id("task-editor-top")

                    Section {
                        DisclosureGroup(isExpanded: $isScheduleExpanded) {
                            scheduleFields
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Schedule")
                                    Text(scheduleSummary)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            } icon: {
                                Image(systemName: "calendar")
                            }
                        }
                        .disclosureGroupStyle(TaskEditorDisclosureStyle(
                            identifier: "task-editor-schedule", beforeToggle: dismissKeyboard
                        ))
                    }

                    Section {
                        DisclosureGroup(isExpanded: $isDetailsExpanded) {
                            detailFields
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Details")
                                    Text(detailsSummary)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            } icon: {
                                Image(systemName: "slider.horizontal.3")
                            }
                        }
                        .disclosureGroupStyle(TaskEditorDisclosureStyle(
                            identifier: "task-editor-details", beforeToggle: dismissKeyboard
                        ))
                    }

                    Section("Link") {
                        TaskEditorLinkFields(url: $draft.url, onFocus: {
                            requestsNameFocus = false
                            notesFocused = false
                        })
                    }

                    subtaskSection

                    if let attachmentModel, let attachmentSelection, AttachmentLinks.enabled(configuration: configuration) {
                        TaskAttachmentSection(
                            model: attachmentModel, selection: attachmentSelection,
                            draft: $draft, configuration: configuration, isImporting: $isImportingAttachments,
                            isEditorPresented: $isEditorPresented
                        )
                    }

                    if let message = displayedValidationMessage ?? saveError {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .accessibilityLabel("Cannot save. \(message)")
                                .accessibilityIdentifier("task-editor-validation")
                        }
                    }
                    if draft.preservedTask == nil && dynamicTypeSize.isAccessibilitySize {
                        Section {
                            saveAnotherButton
                        }
                    }
                }
                .disabled(isSaving)
                .accessibilityIdentifier("task-editor")
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .background(OTodoTheme.formCanvas.ignoresSafeArea())
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if draft.preservedTask == nil && !dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 0) {
                            Divider()
                            saveAnotherButton
                                .buttonStyle(.bordered)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                        }
                        .background(OTodoTheme.formCanvas)
                    }
                }
                .navigationTitle(draft.preservedTask == nil ? "New Todo" : "Edit Todo")
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
                        .accessibilityIdentifier("task-editor-save")
                        .disabled(isSaveDisabled)
                    }

                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done", action: dismissKeyboard)
                            .accessibilityIdentifier("task-editor-keyboard-done")
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
        .onAppear { isEditorPresented = true }
        .onDisappear {
            isEditorPresented = false
            if let attachmentModel, let attachmentSelection {
                let drafts = draft.attachments
                Task { await attachmentModel.discardAttachmentDrafts(drafts, selection: attachmentSelection) }
            }
        }
        .sheet(isPresented: $isParentPickerPresented) {
            TaskParentPicker(
                hierarchy: hierarchy,
                tasks: workspaceTasks,
                taskID: draft.preservedTask?.id,
                parentID: $draft.parentID,
                schemaVersion: configuration.schemaVersion
            )
        }
    }

    private func dismissKeyboard() {
        requestsNameFocus = false
        notesFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private var scheduleSummary: String {
        var parts: [String] = []
        if let date = resolvedDueDate {
            parts.append(date.rawValue)
            if let time = resolvedDueTime { parts.append(time.rawValue) }
        } else {
            parts.append("No due date")
        }
        if let recurrence = draft.recurrence {
            parts.append(recurrenceRule?.frequency.rawValue.capitalized ?? recurrence)
        }
        if hasPendingRelativeDueDate { parts.append("Unapplied date") }
        return parts.joined(separator: " · ")
    }

    private var detailsSummary: String {
        var parts = [configuration.states.first(where: { $0.id == draft.state })?.name ?? draft.state]
        parts.append(contentsOf: TaskEditorDraft.parseCommaSeparated(projectsText))
        parts.append(contentsOf: TaskEditorDraft.parseCommaSeparated(tagsText).map { "#\($0)" })
        if let parentID = draft.parentID {
            parts.append(hierarchy.task(for: parentID)?.name ?? "Missing parent")
        }
        return parts.joined(separator: " · ")
    }

    private var displayedValidationMessage: String? {
        // An untouched blank draft needs a title, not a prominent error banner.
        guard !draft.name.isEmpty else { return nil }
        return validationMessage
    }

    private var scheduleFields: some View {
        Group {
            if draft.preservedTask == nil {
                RelativeDueDateField(
                    accessibilityIdentifierPrefix: "task-editor-relative-due",
                    onPendingChange: { hasPendingRelativeDueDate = $0 },
                    onApply: { resolvedDate, _ in
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
                DatePicker("Date", selection: $dueDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .environment(\.calendar, TaskSchedule.calendar)
                    .accessibilityIdentifier("task-editor-due-date-picker")
                Toggle("Include time", isOn: $hasDueTime)
                    .accessibilityIdentifier("task-editor-due-time-toggle")
                if hasDueTime {
                    DatePicker("Time", selection: $dueDate, displayedComponents: .hourAndMinute)
                        .environment(\.calendar, TaskSchedule.calendar)
                        .accessibilityIdentifier("task-editor-due-time-picker")
                }
            }
            Text(dueDateHelpText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            TaskRecurrenceFields(
                recurrence: $draft.recurrence,
                recurrenceFrom: $draft.recurrenceFrom,
                parsedRule: $recurrenceRule,
                validationError: $recurrenceError,
                initialSettings: initialRecurrenceSettings
            )
            .id(nameFocusRequest)
        }
    }

    private var detailFields: some View {
        Group {
            Picker("State", selection: $draft.state) {
                ForEach(configuration.states, id: \.id) { state in
                    Text(state.name).tag(state.id)
                }
            }
            .accessibilityIdentifier("task-editor-state")

            Button {
                requestsNameFocus = false
                notesFocused = false
                isParentPickerPresented = true
            } label: {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Parent", systemImage: "arrow.turn.down.right")
                        Text(parentDescription)
                            .foregroundStyle(isParentMissing ? .red : .secondary)
                    }
                } else {
                    HStack {
                        Label("Parent", systemImage: "arrow.turn.down.right")
                        Spacer()
                        Text(parentDescription)
                            .foregroundStyle(isParentMissing ? .red : .secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .accessibilityIdentifier("task-editor-parent")
            .buttonStyle(.borderless)
            .accessibilityValue(parentDescription)

            TextField("Projects", text: $projectsText)
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
            TextField("Tags", text: $tagsText)
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
            Text("Projects and tags are comma-separated. Tags don't need #.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var subtaskSection: some View {
        Section("Subtasks") {
            if let taskID = draft.preservedTask?.id {
                ForEach(hierarchy.children(of: taskID), id: \.id) { child in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(child.name)
                        Text(configuration.states.first(where: { $0.id == child.state })?.name ?? child.state)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("task-editor-existing-subtask-\(child.id.rawValue)")
                }
            }
            if configuration.schemaVersion >= 2 {
                ForEach(draft.subtaskNames.indices, id: \.self) { index in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(draft.subtaskNames[index])
                            Text("Not saved yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            draft.subtaskNames.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(draft.subtaskNames[index])")
                        .accessibilityIdentifier("task-editor-remove-subtask-\(index)")
                    }
                }
                TaskEditorSubtaskInput(
                    onFocus: {
                        requestsNameFocus = false
                        notesFocused = false
                    },
                    onPendingChange: { hasPendingSubtask = $0 },
                    onAdd: { draft.subtaskNames.append($0) }
                )
                .id(nameFocusRequest)
                Text("Tap Add to queue each child. Save creates the parent and queued subtasks together. Children start in the default state without inheriting projects, tags, dates, or links.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Subtasks require a schema 2 store. This schema 1 store is not upgraded automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("task-editor-subtasks-unavailable")
            }
        }
    }

    private var saveAnotherButton: some View {
        Button {
            save(createAnother: true)
        } label: {
            Text("Save & Create Another")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityIdentifier("task-editor-save-another")
        .disabled(isSaveDisabled)
    }

    private var parentDescription: String {
        guard let parentID = draft.parentID else { return "No Parent" }
        guard let parent = hierarchy.task(for: parentID) else {
            return "Missing parent · \(parentID.rawValue)"
        }
        return "\(parent.name) · \(parentID.rawValue)"
    }

    private var isParentMissing: Bool {
        draft.parentID.map { hierarchy.task(for: $0) == nil } ?? false
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
        .tint(isSelected ? OTodoTheme.accent : .secondary)
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
        do {
            try DomainValidation.validateURL(normalizedURL)
        } catch {
            return error.localizedDescription
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
        if let recurrenceError { return recurrenceError }
        if let recurrenceRule {
            guard draft.recurrenceFrom != nil else { return "Choose how to count repeats." }
            guard let date = resolvedDueDate else {
                return "Recurring todos require a due date."
            }
            if !recurrenceRule.matches(date) {
                return "The due date must match the repeat selections."
            }
        } else if draft.recurrenceFrom != nil {
            return "Choose a repeat rule or clear its anchor."
        }
        return nil
    }

    private var isSaveDisabled: Bool {
        validationMessage != nil || hasPendingRelativeDueDate || hasPendingSubtask || isImportingAttachments || isSaving
    }

    private func save(createAnother: Bool = false) {
        guard !isSaveDisabled else { return }

        var value = draft
        value.name = detectedDueDatePhrase?.nameWithoutPhrase ?? draft.name
        value.projectSlugs = TaskEditorDraft.parseCommaSeparated(projectsText)
        value.tags = TaskEditorDraft.parseCommaSeparated(tagsText)
        value.dueDate = resolvedDueDate
        value.dueTime = resolvedDueTime
        value.url = normalizedURL
        requestsNameFocus = false
        notesFocused = false
        isSaving = true
        saveError = nil
        didSaveAndContinue = false

        Task { @MainActor in
            let errorMessage = await onSave(value)
            isSaving = false
            if let errorMessage {
                saveError = errorMessage
            } else if createAnother {
                draft.attachments = []
                draft.removingAttachmentPaths = []
                draft.name = ""
                draft.body = ""
                draft.url = nil
                draft.subtaskNames = []
                hasPendingSubtask = false
                draft.dueDate = defaultsToToday ? TaskSchedule.civilDate(from: .now) : nil
                draft.dueTime = nil
                draft.recurrence = nil
                draft.recurrenceFrom = nil
                recurrenceError = nil
                recurrenceRule = nil
                initialRecurrenceSettings = .init(rule: nil, anchor: nil)
                hasDueDate = draft.dueDate != nil
                hasDueTime = false
                dueDate = TaskSchedule.date(from: draft.dueDate, time: nil)
                detectedDueDatePhrase = nil
                hasPendingRelativeDueDate = false
                didSaveAndContinue = true
                isScheduleExpanded = false
                isDetailsExpanded = false
                nameFocusRequest += 1
                requestsNameFocus = true
            } else {
                draft.attachments = []
                dismiss()
            }
        }
    }

    private var normalizedURL: String? {
        guard let value = draft.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private var selectedDueDate: CivilDate? {
        guard hasDueDate else { return nil }
        return TaskSchedule.civilDate(from: dueDate)
    }

    private var selectedDueTime: CivilTime? {
        guard hasDueDate, hasDueTime else { return nil }
        return TaskSchedule.civilTime(from: dueDate)
    }

    private var resolvedDueDate: CivilDate? {
        detectedDueDatePhrase?.resolvedDueDate(selectedDate: selectedDueDate) ?? selectedDueDate
    }

    private var resolvedDueTime: CivilTime? {
        detectedDueDatePhrase?.dueTime ?? selectedDueTime
    }

    private var dueDateHelpText: String {
        if let detectedDueDatePhrase {
            return "The highlighted phrases set \(resolvedDueDate?.rawValue ?? detectedDueDatePhrase.dueDate.rawValue)\(resolvedDueTime.map { " at \($0.rawValue)" } ?? "") when saved. A time-only phrase keeps your selected calendar date."
        }
        guard hasDueDate else {
            return "This todo has no due date."
        }
        if hasDueTime {
            return "Choose the calendar date and exact due time."
        }
        return "Choose a calendar date. Date-only reminders are based on 9:00 AM, with the lead time from Due reminders settings."
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

private struct TaskEditorLinkFields: View {
    @Binding var url: String?
    let onFocus: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            TextField("https://example.com", text: Binding(
                get: { url ?? "" },
                set: { url = $0.isEmpty ? nil : $0 }
            ))
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("Todo link")
            .accessibilityIdentifier("task-editor-url")
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                if focused { onFocus() }
            }
            if url != nil {
                Button {
                    url = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear link")
                .accessibilityIdentifier("task-editor-clear-url")
            }
        }
        if let destination {
            Link(destination: destination) {
                Label("Open Link", systemImage: "arrow.up.right.square")
            }
            .accessibilityHint("Opens this URL in your browser")
            .accessibilityIdentifier("task-editor-open-url")
        }
    }

    private var destination: URL? {
        guard let value = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        do {
            try DomainValidation.validateURL(value)
            return URL(string: value)
        } catch {
            return nil
        }
    }
}

/// Only Add and pending-state transitions reach the parent; typing never rebuilds date inputs.
private struct TaskEditorSubtaskInput: View {
    let onFocus: () -> Void
    let onPendingChange: (Bool) -> Void
    let onAdd: (String) -> Void
    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("New subtask name", text: $name)
                .accessibilityLabel("New subtask name")
                .accessibilityIdentifier("task-editor-subtask-name")
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(add)
                .onChange(of: isFocused) { _, focused in
                    if focused { onFocus() }
                }
                .onChange(of: !name.isEmpty) { _, pending in
                    onPendingChange(pending)
                }
            HStack {
                Button("Add Subtask", systemImage: "plus", action: add)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("task-editor-subtask-add")
                    .disabled(!canAdd)
                if !name.isEmpty {
                    Spacer()
                    Button("Clear") { name = "" }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Clear new subtask name")
                        .accessibilityIdentifier("task-editor-subtask-clear")
                }
            }
        }
    }

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.contains("\n") && !name.contains("\r")
    }

    private func add() {
        guard canAdd else { return }
        onAdd(name.trimmingCharacters(in: .whitespacesAndNewlines))
        name = ""
        onPendingChange(false)
    }
}

/// Keep input subtrees mounted while collapsed, so child-owned date parser and
/// invalid recurrence text survive opening and closing a panel.
private struct TaskEditorDisclosureStyle: DisclosureGroupStyle {
    let identifier: String
    let beforeToggle: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                beforeToggle()
                withAnimation(.easeInOut(duration: 0.2)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack {
                    configuration.label
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

            VStack(alignment: .leading, spacing: 16) {
                configuration.content
            }
            .buttonStyle(.borderless)
            .padding(.top, configuration.isExpanded ? 20 : 0)
            .frame(height: configuration.isExpanded ? nil : 0, alignment: .top)
            .clipped()
            .opacity(configuration.isExpanded ? 1 : 0)
            .disabled(!configuration.isExpanded)
            .allowsHitTesting(configuration.isExpanded)
            .accessibilityHidden(!configuration.isExpanded)
        }
    }
}

/// Recurrence input owns its transient text and selections, just like relative-date input.
/// Only recurrence edits publish a new rule; opening an imported task preserves its source rule.
private struct TaskRecurrenceFields: View {
    @Binding private var recurrence: String?
    @Binding private var recurrenceFrom: RecurrenceFrom?
    @Binding private var parsedRule: RecurrenceRule?
    @Binding private var validationError: String?
    @State private var settings: Settings

    fileprivate struct Settings: Equatable {
        var frequency: RecurrenceFrequency?
        var interval: String
        var weekdays: Set<RecurrenceWeekday>
        var monthDays: Set<Int>
        var months: Set<Int>
        var anchor: RecurrenceFrom

        init(rule: RecurrenceRule?, anchor: RecurrenceFrom?) {
            frequency = rule?.frequency
            interval = rule.map { String($0.interval) } ?? "1"
            weekdays = Set(rule?.byDay ?? [])
            monthDays = Set(rule?.byMonthDay ?? [])
            months = Set(rule?.byMonth ?? [])
            self.anchor = anchor ?? .schedule
        }
    }

    init(
        recurrence: Binding<String?>,
        recurrenceFrom: Binding<RecurrenceFrom?>,
        parsedRule: Binding<RecurrenceRule?>,
        validationError: Binding<String?>,
        initialSettings: Settings
    ) {
        _recurrence = recurrence
        _recurrenceFrom = recurrenceFrom
        _parsedRule = parsedRule
        _validationError = validationError
        _settings = State(initialValue: initialSettings)
    }

    var body: some View {
        Group {
            Picker("Repeat", selection: $settings.frequency) {
                Text("None").tag(nil as RecurrenceFrequency?)
                ForEach(RecurrenceFrequency.allCases, id: \.self) { frequency in
                    Text(frequency.rawValue.capitalized).tag(Optional(frequency))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("task-editor-repeat")

            if let frequency = settings.frequency {
                HStack {
                    Text("Every")
                    TextField("1", text: $settings.interval)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Repeat interval")
                        .accessibilityIdentifier("task-editor-repeat-interval")
                    Text(intervalUnit(for: frequency))
                        .foregroundStyle(.secondary)
                }

                if frequency == .weekly {
                    Menu {
                        ForEach(RecurrenceWeekday.allCases, id: \.self) { weekday in
                            Toggle(weekdayName(weekday), isOn: selection(weekday, in: $settings.weekdays))
                                .accessibilityIdentifier("task-editor-repeat-weekday-\(weekday.rawValue)")
                        }
                    } label: {
                        selectionLabel(
                            "Weekdays",
                            value: settings.weekdays.isEmpty ? "Anchor weekday" :
                                RecurrenceWeekday.allCases.filter { settings.weekdays.contains($0) }
                                    .map { weekdayName($0) }.joined(separator: ", ")
                        )
                    }
                    .accessibilityIdentifier("task-editor-repeat-weekdays")
                }

                if frequency == .monthly || frequency == .yearly {
                    Menu {
                        ForEach(1 ... 31, id: \.self) { day in
                            Toggle(String(day), isOn: selection(day, in: $settings.monthDays))
                                .accessibilityIdentifier("task-editor-repeat-month-day-\(day)")
                        }
                    } label: {
                        selectionLabel(
                            "Days of month",
                            value: settings.monthDays.isEmpty ? "Anchor day" :
                                settings.monthDays.sorted().map(String.init).joined(separator: ", ")
                        )
                    }
                    .accessibilityIdentifier("task-editor-repeat-month-days")
                }

                if frequency == .yearly {
                    Menu {
                        ForEach(1 ... 12, id: \.self) { month in
                            Toggle(monthName(month), isOn: selection(month, in: $settings.months))
                                .accessibilityIdentifier("task-editor-repeat-month-\(month)")
                        }
                    } label: {
                        selectionLabel(
                            "Months",
                            value: settings.months.isEmpty ? "Anchor month" :
                                settings.months.sorted().map { monthName($0) }.joined(separator: ", ")
                        )
                    }
                    .accessibilityIdentifier("task-editor-repeat-months")
                }

                Picker("Count from", selection: $settings.anchor) {
                    Text("Scheduled date").tag(RecurrenceFrom.schedule)
                    Text("Completion date").tag(RecurrenceFrom.completion)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("task-editor-repeat-anchor")
            }
            Group {
                if settings.frequency != nil {
                    Text(
                        (settings.anchor == .schedule
                            ? "Completing an occurrence keeps the original schedule and skips missed dates."
                            : "Completing an occurrence starts the interval from the day you complete it.")
                        + " A due date matching any selections is required. Empty selections use the anchor date. Impossible dates are skipped, never shortened."
                        + " Choose a terminal State to finish the series without scheduling another occurrence."
                    )
                } else {
                    Text("None makes this a one-off todo. Previously recorded completions stay in Stats.")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .onChange(of: settings) { _, _ in publishRule() }
    }

    private func publishRule() {
        guard let frequency = settings.frequency else {
            parsedRule = nil
            recurrence = nil
            recurrenceFrom = nil
            validationError = nil
            return
        }
        guard let interval = UInt64(settings.interval), interval > 0 else {
            validationError = "Repeat interval must be a positive whole number."
            return
        }
        do {
            let rule = try RecurrenceRule(
                frequency: frequency,
                interval: interval,
                byDay: frequency == .weekly ? Array(settings.weekdays) : [],
                byMonthDay: frequency == .monthly || frequency == .yearly ? Array(settings.monthDays) : [],
                byMonth: frequency == .yearly ? Array(settings.months) : []
            )
            parsedRule = rule
            recurrence = rule.description
            recurrenceFrom = settings.anchor
            validationError = nil
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func selection<Value: Hashable>(
        _ value: Value,
        in values: Binding<Set<Value>>
    ) -> Binding<Bool> {
        Binding(
            get: { values.wrappedValue.contains(value) },
            set: { selected in
                if selected {
                    values.wrappedValue.insert(value)
                } else {
                    values.wrappedValue.remove(value)
                }
            }
        )
    }

    private func selectionLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func intervalUnit(for frequency: RecurrenceFrequency) -> String {
        switch frequency {
        case .daily: "day(s)"
        case .weekly: "week(s)"
        case .monthly: "month(s)"
        case .yearly: "year(s)"
        }
    }

    private func weekdayName(_ weekday: RecurrenceWeekday) -> String {
        switch weekday {
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        case .sunday: "Sunday"
        }
    }

    private func monthName(_ month: Int) -> String {
        TaskSchedule.calendar.monthSymbols[month - 1]
    }
}
