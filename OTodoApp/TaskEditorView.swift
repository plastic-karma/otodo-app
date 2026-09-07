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
                            highlightRange: detectedDueDatePhrase?.utf16Range,
                            accessibilityIdentifier: "task-editor-name",
                            requestsFocus: $requestsNameFocus
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
                }
                .disabled(isSaving)
                .accessibilityIdentifier("task-editor")
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
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

                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done", action: dismissKeyboard)
                            .accessibilityIdentifier("task-editor-keyboard-done")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if draft.preservedTask == nil {
                        Button("Save & Create Another") {
                            save(createAnother: true)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("task-editor-save-another")
                        .disabled(isSaveDisabled)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.bar)
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
        if let date = detectedDueDatePhrase?.dueDate ?? selectedDueDate {
            parts.append(date.rawValue)
            if let time = selectedDueTime { parts.append(time.rawValue) }
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
                HStack {
                    Label("Parent", systemImage: "arrow.turn.down.right")
                    Spacer()
                    Text(parentDescription)
                        .foregroundStyle(isParentMissing ? .red : .secondary)
                        .multilineTextAlignment(.trailing)
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
        if let recurrenceError { return recurrenceError }
        if let recurrenceRule {
            guard draft.recurrenceFrom != nil else { return "Choose how to count repeats." }
            guard let date = detectedDueDatePhrase?.dueDate ?? selectedDueDate else {
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
        validationMessage != nil || hasPendingRelativeDueDate || isImportingAttachments || isSaving
    }

    private func save(createAnother: Bool = false) {
        guard !isSaveDisabled else { return }

        var value = draft
        value.name = detectedDueDatePhrase?.nameWithoutPhrase ?? draft.name
        value.projectSlugs = TaskEditorDraft.parseCommaSeparated(projectsText)
        value.tags = TaskEditorDraft.parseCommaSeparated(tagsText)
        value.dueDate = detectedDueDatePhrase?.dueDate ?? selectedDueDate
        value.dueTime = selectedDueTime
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
                    Text("None makes this a one-off todo and clears its completion history.")
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
