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
    var recurrence: String?
    var recurrenceFrom: RecurrenceFrom?
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
    @State private var recurrenceError: String?
    @State private var recurrenceRule: RecurrenceRule?
    @State private var initialRecurrenceSettings: TaskRecurrenceFields.Settings
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var didSaveAndContinue = false
    @State private var nameFocusRequest = 0
    @State private var requestsNameFocus = false

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

                    TaskRecurrenceFields(
                        recurrence: $draft.recurrence,
                        recurrenceFrom: $draft.recurrenceFrom,
                        parsedRule: $recurrenceRule,
                        validationError: $recurrenceError,
                        initialSettings: initialRecurrenceSettings
                    )
                    .id(nameFocusRequest)

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
                                .accessibilityIdentifier("task-editor-validation")
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
        requestsNameFocus = false
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
                draft.recurrence = nil
                draft.recurrenceFrom = nil
                recurrenceError = nil
                recurrenceRule = nil
                initialRecurrenceSettings = .init(rule: nil, anchor: nil)
                hasDueDate = false
                hasDueTime = false
                dueDate = TaskSchedule.date(from: nil, time: nil)
                detectedDueDatePhrase = nil
                hasPendingRelativeDueDate = false
                didSaveAndContinue = true
                nameFocusRequest += 1
                requestsNameFocus = true
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
        Section {
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
        } header: {
            Text("Repeat")
        } footer: {
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
