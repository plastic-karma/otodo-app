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
    var completesOccurrence = false

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
    @Environment(\.locale) private var locale

    private let attachmentModel: AppModel?
    private let attachmentSelection: RepositorySelection?
    private let configuration: StoreConfiguration
    private let projectChoices: [String]
    private let projectChoiceSet: Set<String>
    private let tagChoices: [String]
    private let tagChoiceSet: Set<String>
    private let hierarchy: TaskHierarchy
    private let workspaceTasks: [TodoTask]
    private let onSave: @MainActor (TaskEditorDraft) async -> String?
    private let defaultDueDate: CivilDate?

    private var workflowStates: [WorkflowState] {
        attachmentModel?.configuration?.states ?? configuration.states
    }

    @State private var draft: TaskEditorDraft
    @State private var projectsText: String
    @State private var tagsText: String
    @State private var hasDueDate: Bool
    @State private var hasDueTime: Bool
    @State private var dueDate: Date
    @State private var hasPendingRelativeDueDate = false
    @State private var detectedDueDatePhrase: DetectedDueDatePhrase?
    @State private var detectedNotesDueDatePhrase: DetectedDueDatePhrase?
    @State private var nameProjectMentions: TaskTextMentions
    @State private var nameTagMentions: TaskTextMentions
    @State private var notesProjectMentions: TaskTextMentions
    @State private var notesTagMentions: TaskTextMentions
    @State private var detectedProjects: [String]
    @State private var detectedTags: [String]
    @State private var nameHighlightRanges: [NSRange]
    @State private var nameSelection: NSRange
    @State private var notesSelection: NSRange
    @State private var nameFocused = false
    @State private var nameComposing = false
    @State private var notesComposing = false
    @ScaledMetric(relativeTo: .body) private var notesHeight = 96
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
    @State private var queuedSubtasks: [QueuedSubtask]
    @State private var notesFocused = false
    @State private var isScheduleExpanded = false
    @State private var isDetailsExpanded = false
    @State private var childEditorPresentation: EditorPresentation?
    @State private var childReschedulePresentation: ReschedulePresentation?
    @State private var isAddingInProgressState = false
    @State private var workflowError: String?
    @State private var isArchiveConfirmationPresented = false

    init(
        draft: TaskEditorDraft,
        configuration: StoreConfiguration,
        projectChoices: [String],
        tagChoices: [String],
        hierarchy: TaskHierarchy = TaskHierarchy(tasks: []),
        workspaceTasks: [TodoTask] = [],
        attachmentModel: AppModel? = nil,
        defaultDueDate: CivilDate? = nil,
        onSave: @escaping @MainActor (TaskEditorDraft) async -> String?
    ) {
        self.attachmentModel = attachmentModel
        self.attachmentSelection = attachmentModel?.workspaceSelection
        self.configuration = configuration
        self.projectChoices = projectChoices
        self.projectChoiceSet = Set(projectChoices)
        self.tagChoices = tagChoices
        self.tagChoiceSet = Set(tagChoices.map { $0.lowercased() })
        self.hierarchy = hierarchy
        self.workspaceTasks = workspaceTasks
        self.onSave = onSave
        self.defaultDueDate = defaultDueDate
        _draft = State(initialValue: draft)
        _queuedSubtasks = State(initialValue: draft.subtaskNames.map { QueuedSubtask(name: $0) })
        _projectsText = State(initialValue: draft.projectSlugs.joined(separator: ", "))
        _tagsText = State(initialValue: draft.tags.joined(separator: ", "))
        _hasDueDate = State(initialValue: draft.dueDate != nil)
        _hasDueTime = State(initialValue: draft.dueTime != nil)
        _dueDate = State(initialValue: TaskSchedule.date(from: draft.dueDate, time: draft.dueTime))
        let duePhrase = Self.detectDueDatePhrase(in: draft.name)
        let notesDuePhrase = Self.detectDueDatePhrase(in: draft.body)
        let nameProjectMentions = TaskTextMentions(in: draft.name, marker: "#")
        let nameTagMentions = TaskTextMentions(in: draft.name, marker: "@")
        let notesProjectMentions = TaskTextMentions(in: draft.body, marker: "#")
        let notesTagMentions = TaskTextMentions(in: draft.body, marker: "@")
        _detectedDueDatePhrase = State(initialValue: duePhrase)
        _detectedNotesDueDatePhrase = State(initialValue: notesDuePhrase)
        _nameProjectMentions = State(initialValue: nameProjectMentions)
        _nameTagMentions = State(initialValue: nameTagMentions)
        _notesProjectMentions = State(initialValue: notesProjectMentions)
        _notesTagMentions = State(initialValue: notesTagMentions)
        _detectedProjects = State(initialValue: Array(Set(
            nameProjectMentions.recognizedValues(from: projectChoices)
                + notesProjectMentions.recognizedValues(from: projectChoices)
        )).sorted())
        _detectedTags = State(initialValue: Array(Set(
            nameTagMentions.recognizedValues(from: tagChoices)
                + notesTagMentions.recognizedValues(from: tagChoices)
        )).sorted())
        _nameHighlightRanges = State(initialValue: (duePhrase?.utf16Ranges ?? [])
            + Self.mentionHighlightRanges(nameProjectMentions, choices: Set(projectChoices))
            + Self.mentionHighlightRanges(nameTagMentions, choices: tagChoiceSet))
        _nameSelection = State(initialValue: NSRange(location: draft.name.utf16.count, length: 0))
        _notesSelection = State(initialValue: NSRange(location: draft.body.utf16.count, length: 0))
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
                            highlightRanges: nameHighlightRanges,
                            accessibilityIdentifier: "task-editor-name",
                            requestsFocus: $requestsNameFocus,
                            selection: $nameSelection, isFocused: $nameFocused,
                            isComposing: $nameComposing
                        )
                        .frame(minHeight: 44)
                        .onChange(of: draft.name) { _, name in
                            detectedDueDatePhrase = Self.detectDueDatePhrase(in: name)
                            nameProjectMentions = TaskTextMentions(in: name, marker: "#")
                            nameTagMentions = TaskTextMentions(in: name, marker: "@")
                            nameHighlightRanges = (detectedDueDatePhrase?.utf16Ranges ?? [])
                                + Self.mentionHighlightRanges(nameProjectMentions, choices: projectChoiceSet)
                                + Self.mentionHighlightRanges(nameTagMentions, choices: tagChoiceSet)
                            refreshDetectedMentions()
                        }
                        .onChange(of: nameFocused) { _, focused in
                            if focused { notesFocused = false }
                        }
                        if nameFocused, !nameComposing {
                            mentionSuggestions(
                                nameProjectMentions.suggestions(at: nameSelection, choices: projectChoices),
                                field: "name", kind: .project
                            ) { suggestion in
                                guard let result = suggestion.applying(to: draft.name) else { return }
                                draft.name = result.text
                                nameSelection = result.selection
                                requestsNameFocus = true
                            }
                            mentionSuggestions(
                                nameTagMentions.suggestions(at: nameSelection, choices: tagChoices),
                                field: "name", kind: .tag
                            ) { suggestion in
                                guard let result = suggestion.applying(to: draft.name) else { return }
                                draft.name = result.text
                                nameSelection = result.selection
                                requestsNameFocus = true
                            }
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
                            TaskTextEditor(
                                text: $draft.body, selection: $notesSelection,
                                isFocused: $notesFocused, isComposing: $notesComposing,
                                style: .notes
                            )
                                .frame(height: notesHeight)
                                .onChange(of: draft.body) { _, text in
                                    detectedNotesDueDatePhrase = Self.detectDueDatePhrase(in: text)
                                    let projectMentions = TaskTextMentions(in: text, marker: "#")
                                    let tagMentions = TaskTextMentions(in: text, marker: "@")
                                    notesProjectMentions = projectMentions
                                    notesTagMentions = tagMentions
                                    refreshDetectedMentions()
                                    let suggestionID: String?
                                    if !tagMentions.suggestions(at: notesSelection, choices: tagChoices).isEmpty {
                                        suggestionID = "task-editor-notes-tag-suggestions"
                                    } else if !projectMentions.suggestions(
                                        at: notesSelection, choices: projectChoices
                                    ).isEmpty {
                                        suggestionID = "task-editor-notes-project-suggestions"
                                    } else {
                                        suggestionID = nil
                                    }
                                    if let suggestionID {
                                        Task { @MainActor in
                                            await Task.yield()
                                            proxy.scrollTo(suggestionID, anchor: .bottom)
                                        }
                                    }
                                }
                                .onChange(of: notesFocused) { _, focused in
                                    if focused {
                                        requestsNameFocus = false
                                        nameFocused = false
                                    }
                                }
                        }
                        .listRowSeparator(.hidden)
                        if detectedDueDatePhrase == nil, let detectedNotesDueDatePhrase {
                            let explanation =
                                "Due \(resolvedDueDate?.rawValue ?? detectedNotesDueDatePhrase.dueDate.rawValue)\(resolvedDueTime.map { " at \($0.rawValue)" } ?? "") · “\(detectedNotesDueDatePhrase.phrases.joined(separator: "” and “"))” in notes will be removed when saved"
                            Label(explanation, systemImage: "calendar.badge.checkmark")
                                .font(.footnote)
                                .foregroundStyle(OTodoTheme.accent)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(explanation)
                                .accessibilityIdentifier("task-editor-detected-notes-due-date")
                        }
                        if notesFocused, !notesComposing {
                            mentionSuggestions(
                                notesProjectMentions.suggestions(at: notesSelection, choices: projectChoices),
                                field: "notes", kind: .project
                            ) { suggestion in
                                guard let result = suggestion.applying(to: draft.body) else { return }
                                draft.body = result.text
                                notesSelection = result.selection
                            }
                            .id("task-editor-notes-project-suggestions")
                            mentionSuggestions(
                                notesTagMentions.suggestions(at: notesSelection, choices: tagChoices),
                                field: "notes", kind: .tag
                            ) { suggestion in
                                guard let result = suggestion.applying(to: draft.body) else { return }
                                draft.body = result.text
                                notesSelection = result.selection
                            }
                            .id("task-editor-notes-tag-suggestions")
                        }
                        if !detectedProjects.isEmpty {
                            let explanation = "Projects from #mentions: \(detectedProjects.joined(separator: ", "))"
                            Label(explanation, systemImage: "folder.badge.plus")
                                .font(.footnote)
                                .foregroundStyle(OTodoTheme.accent)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(explanation)
                                .accessibilityIdentifier("task-editor-detected-projects")
                        }
                        if !detectedTags.isEmpty {
                            let explanation = "Tags from @mentions: \(detectedTags.joined(separator: ", "))"
                            Label(explanation, systemImage: "tag.fill")
                                .font(.footnote)
                                .foregroundStyle(OTodoTheme.accent)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(explanation)
                                .accessibilityIdentifier("task-editor-detected-tags")
                        }
                    }
                    .id("task-editor-top")

                    Section {
                        if draft.preservedTask != nil {
                            editorActions
                        } else {
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
                            bodyText: draft.body,
                            taskPath: draft.preservedTask?.relativePath ?? configuration.tasksDirectory + "/draft.md",
                            storePrefix: configuration.obsidianLinkPrefix,
                            attachments: $draft.attachments,
                            removingAttachmentPaths: $draft.removingAttachmentPaths,
                            isImporting: $isImportingAttachments,
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
                .disabled(isSaving || attachmentModel?.isBusy == true)
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
                .interactiveDismissDisabled(isSaving || attachmentModel?.isBusy == true)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) {
                            dismiss()
                        }
                        .disabled(isSaving || attachmentModel?.isBusy == true)
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
        .onChange(of: draft.parentID) { _, parentID in
            guard draft.preservedTask == nil,
                  let parentID,
                  let parent = hierarchy.task(for: parentID)
            else { return }
            projectsText = parent.projectSlugs.joined(separator: ", ")
        }
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
        .sheet(item: $childEditorPresentation) { presentation in
            if let model = attachmentModel {
                TaskEditorView(
                    draft: presentation.draft, configuration: configuration,
                    projectChoices: model.projectChoices, tagChoices: model.tagChoices,
                    hierarchy: model.hierarchy, workspaceTasks: model.tasks, attachmentModel: model
                ) { value in
                    switch presentation {
                    case .create:
                        await model.createTask(draft: value)
                    case let .edit(task):
                        await model.updateTask(id: task.id, draft: value)
                    }
                    return model.errorMessage
                }
                .id(presentation.id)
                .presentationDetents([.large])
            }
        }
        .sheet(item: $childReschedulePresentation) { presentation in
            if let model = attachmentModel {
                TaskRescheduleView(tasks: presentation.tasks) { date, time in
                    await model.rescheduleTasks(presentation.tasks, dueDate: date, dueTime: time)
                    return model.errorMessage
                }
                .presentationDetents([.large])
            }
        }
        .confirmationDialog(
            "Archive this todo?",
            isPresented: $isArchiveConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive, action: archive)
                .accessibilityIdentifier("task-editor-archive-confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("task-editor-archive-cancel")
        } message: {
            Text("Archive deletes this todo using the same action as Delete. It does not keep an archived copy. Unsaved edits will be discarded.")
        }
        .confirmationDialog(
            "Add In Progress to this workspace?",
            isPresented: $isAddingInProgressState,
            titleVisibility: .visible
        ) {
            if let attachmentModel {
                Button("Add state") {
                    Task { @MainActor in
                        await attachmentModel.addInProgressState()
                        workflowError = attachmentModel.errorMessage
                    }
                }
                .accessibilityIdentifier("workflow-enable-in-progress-confirm")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This adds a nonterminal in-progress state to the selected store’s shared .todo/config.toml on GitHub. Existing states, their order, the default state, and this todo stay unchanged. An internet connection and repository write access are required.")
        }
    }

    private func dismissKeyboard() {
        requestsNameFocus = false
        notesFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private var canFinish: Bool {
        workflowStates.first(where: { $0.id == draft.state })?.isTerminal == false
            && workflowStates.contains(where: \.isTerminal)
    }

    private var editorActions: some View {
        VStack(alignment: .leading, spacing: 0) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Button {
                    dismissKeyboard()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isScheduleExpanded.toggle()
                    }
                } label: {
                    editorActionLabel("Change schedule", systemImage: "calendar", color: OTodoTheme.accent)
                }
                .accessibilityIdentifier("task-editor-schedule")
                .accessibilityValue(isScheduleExpanded ? "Expanded" : "Collapsed")

                Button {
                    save(completing: true)
                } label: {
                    editorActionLabel("Finish", systemImage: "checkmark.circle", color: OTodoTheme.accent)
                }
                .disabled(isSaveDisabled || !canFinish)
                .accessibilityIdentifier("task-editor-finish")
                .accessibilityHint("Saves edits and completes this todo or its current repeat occurrence")

                Button(role: .destructive) {
                    dismissKeyboard()
                    isArchiveConfirmationPresented = true
                } label: {
                    editorActionLabel("Archive", systemImage: "archivebox", color: .red)
                }
                .disabled(attachmentModel == nil || isImportingAttachments)
                .accessibilityIdentifier("task-editor-archive")
                .accessibilityHint("Asks before deleting this todo")
            }
            .buttonStyle(.plain)

            Text(scheduleSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            // Keep recurrence input mounted so collapsing never clears an invalid edit.
            VStack(alignment: .leading, spacing: 16) {
                scheduleFields
            }
            .buttonStyle(.borderless)
            .padding(.top, isScheduleExpanded ? 20 : 0)
            .frame(height: isScheduleExpanded ? nil : 0, alignment: .top)
            .clipped()
            .opacity(isScheduleExpanded ? 1 : 0)
            .disabled(!isScheduleExpanded)
            .allowsHitTesting(isScheduleExpanded)
            .accessibilityHidden(!isScheduleExpanded)
        }
    }

    private func editorActionLabel(_ title: LocalizedStringKey, systemImage: String, color: Color) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(spacing: 8))
            : AnyLayout(VStackLayout(spacing: 6))
        return layout {
            Image(systemName: systemImage)
                .font(.title3)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .foregroundStyle(color)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    private func archive() {
        guard !isSaving, !isImportingAttachments,
              let model = attachmentModel, !model.isBusy,
              let task = draft.preservedTask else { return }
        isSaving = true
        saveError = nil
        Task { @MainActor in
            await model.deleteTask(task)
            isSaving = false
            if let error = model.errorMessage {
                saveError = error
            } else {
                dismiss()
            }
        }
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
            if let recurrenceRule {
                var title = recurrenceRule.frequency.editorTitle
                title.locale = locale
                parts.append(String(localized: title))
            } else {
                parts.append(recurrence)
            }
        }
        if hasPendingRelativeDueDate { parts.append("Unapplied date") }
        return parts.joined(separator: " · ")
    }

    private var detailsSummary: String {
        var parts = [workflowStates.first(where: { $0.id == draft.state })?.name ?? draft.state]
        parts.append(contentsOf: projectsIncludingMentions)
        parts.append(contentsOf: tagsIncludingMentions.map { "@\($0)" })
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
        TaskEditorScheduleFields(
            isNewTask: draft.preservedTask == nil,
            hasDueDate: $hasDueDate,
            hasDueTime: $hasDueTime,
            dueDate: $dueDate,
            hasPendingRelativeDueDate: $hasPendingRelativeDueDate,
            saveError: $saveError,
            recurrence: $draft.recurrence,
            recurrenceFrom: $draft.recurrenceFrom,
            recurrenceRule: $recurrenceRule,
            recurrenceError: $recurrenceError,
            initialRecurrenceSettings: initialRecurrenceSettings,
            helpText: dueDateHelpText
        )
        .id(nameFocusRequest)
    }

    @ViewBuilder
    private var workflowSetupFields: some View {
        if attachmentModel != nil, !workflowStates.contains(where: \.isInProgress) {
            Button {
                dismissKeyboard()
                workflowError = nil
                isAddingInProgressState = true
            } label: {
                Label("Add In Progress state…", systemImage: "play.circle")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("task-editor-enable-in-progress")
            .buttonStyle(.borderless)
            .foregroundStyle(OTodoTheme.accent)
            if let workflowError {
                Text(workflowError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("task-editor-workflow-error")
            }
        }
    }

    private var detailFields: some View {
        Group {
            Picker("State", selection: $draft.state) {
                ForEach(workflowStates, id: \.id) { state in
                    Text(state.name).tag(state.id)
                }
            }
            .accessibilityIdentifier("task-editor-state")

            workflowSetupFields

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

            TaskEditorClassificationFields(
                projectsText: $projectsText, tagsText: $tagsText,
                projectChoices: projectChoices, tagChoices: tagChoices,
                detectedProjects: detectedProjects, detectedTags: detectedTags
            )
        }
    }

    private var subtaskSection: some View {
        Section("Subtasks") {
            if let taskID = draft.preservedTask?.id {
                ForEach((attachmentModel?.hierarchy ?? hierarchy).children(of: taskID), id: \.id) { child in
                    if let model = attachmentModel {
                        TaskRowView(
                            task: child,
                            workflowState: workflowStates.first { $0.id == child.state },
                            today: TodayWidgetSnapshotBuilder.dateKey(for: .now),
                            isCompletionDisabled: model.isBusy || TaskRowActions.completionTarget(for: child, in: model) == nil,
                            onOpen: { childEditorPresentation = .edit(child) },
                            onToggleCompletion: { TaskRowActions.toggleCompletion(child, in: model) },
                            rowIdentifier: "task-editor-existing-subtask-\(child.id.rawValue)"
                        )
                        .modifier(TaskRowActions(
                            task: child, model: model,
                            onAddSubtask: { presentSubtask(of: child) },
                            onReschedule: { childReschedulePresentation = ReschedulePresentation(tasks: [child]) }
                        ))
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(child.name)
                            Text(workflowStates.first(where: { $0.id == child.state })?.name ?? child.state)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("task-editor-existing-subtask-\(child.id.rawValue)")
                    }
                }
            }
            if let message = attachmentModel?.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("subtask-action-error")
            }
            if configuration.schemaVersion >= 2 {
                ForEach(Array(queuedSubtasks.enumerated()), id: \.element.id) { index, subtask in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(subtask.name)
                            Text("Not saved yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            queuedSubtasks.removeAll { $0.id == subtask.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(subtask.name)")
                        .accessibilityIdentifier("task-editor-remove-subtask-\(index)")
                    }
                }
                TaskEditorSubtaskInput(
                    onFocus: {
                        requestsNameFocus = false
                        notesFocused = false
                    },
                    onPendingChange: { hasPendingSubtask = $0 },
                    onAdd: { queuedSubtasks.append(QueuedSubtask(name: $0)) }
                )
                .id(nameFocusRequest)
                Text("Tap + to queue each child. Save creates the parent and queued subtasks together with the parent's projects, without inheriting tags, dates, or links. Completing the parent also completes its active subtasks.")
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

    private struct QueuedSubtask: Identifiable {
        let id = UUID()
        let name: String
    }

    private func presentSubtask(of task: TodoTask) {
        var child = TaskEditorDraft(configuration: configuration)
        child.parentID = task.id
        child.projectSlugs = task.projectSlugs
        childEditorPresentation = .create(child, id: UUID())
    }

    private var projectsIncludingMentions: [String] {
        let explicit = TaskEditorDraft.parseCommaSeparated(projectsText)
        let selected = Set(explicit)
        return explicit + detectedProjects.filter { !selected.contains($0) }
    }

    private var tagsIncludingMentions: [String] {
        let explicit = TaskEditorDraft.parseCommaSeparated(tagsText)
        let selected = Set(explicit)
        return explicit + detectedTags.filter { !selected.contains($0) }
    }

    private func refreshDetectedMentions() {
        detectedProjects = Array(Set(
            nameProjectMentions.recognizedValues(from: projectChoices)
                + notesProjectMentions.recognizedValues(from: projectChoices)
        )).sorted()
        detectedTags = Array(Set(
            nameTagMentions.recognizedValues(from: tagChoices)
                + notesTagMentions.recognizedValues(from: tagChoices)
        )).sorted()
    }

    private static func mentionHighlightRanges(_ mentions: TaskTextMentions, choices: Set<String>) -> [NSRange] {
        mentions.tokens.compactMap { token in
            choices.contains(token.value.lowercased()) ? token.utf16Range : nil
        }
    }

    private enum MentionKind {
        case project
        case tag

        var marker: Character { self == .project ? "#" : "@" }
        var name: String { self == .project ? "Project" : "Tag" }
        var identifier: String { self == .project ? "project" : "tag" }
        var systemImage: String { self == .project ? "folder" : "tag.fill" }
        var pluralName: String { self == .project ? "projects" : "tags" }
    }

    @ViewBuilder
    private func mentionSuggestions(
        _ suggestions: [TaskTextMentions.Suggestion], field: String, kind: MentionKind,
        onSelect: @escaping (TaskTextMentions.Suggestion) -> Void
    ) -> some View {
        if !suggestions.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.value) { suggestion in
                        Button {
                            onSelect(suggestion)
                        } label: {
                            Label("\(kind.marker)\(suggestion.value)", systemImage: kind.systemImage)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("\(kind.name): \(suggestion.value)")
                        .accessibilityIdentifier("task-editor-\(field)-\(kind.identifier)-suggestion-\(suggestion.value)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityLabel("Matching existing \(kind.pluralName)")
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
        if !workflowStates.contains(where: { $0.id == draft.state }) {
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
        validationMessage != nil || hasPendingRelativeDueDate || hasPendingSubtask
            || isImportingAttachments || isSaving || attachmentModel?.isBusy == true
    }

    private func save(createAnother: Bool = false, completing: Bool = false) {
        guard !isSaveDisabled, !completing || canFinish else { return }

        var value = draft
        value.completesOccurrence = completing
        value.name = detectedDueDatePhrase?.nameWithoutPhrase ?? draft.name
        if detectedDueDatePhrase == nil, let detectedNotesDueDatePhrase {
            value.body = detectedNotesDueDatePhrase.textWithoutPhrasePreservingLayout
        }
        value.projectSlugs = projectsIncludingMentions
        value.tags = tagsIncludingMentions
        value.dueDate = resolvedDueDate
        value.dueTime = resolvedDueTime
        value.url = normalizedURL
        value.subtaskNames = queuedSubtasks.map(\.name)
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
                projectsText = value.projectSlugs.joined(separator: ", ")
                tagsText = value.tags.joined(separator: ", ")
                nameSelection = NSRange(location: 0, length: 0)
                notesSelection = NSRange(location: 0, length: 0)
                draft.attachments = []
                draft.removingAttachmentPaths = []
                draft.name = ""
                draft.body = ""
                draft.url = nil
                queuedSubtasks = []
                hasPendingSubtask = false
                draft.dueDate = defaultDueDate
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
                detectedNotesDueDatePhrase = nil
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

    private var activeDueDatePhrase: DetectedDueDatePhrase? {
        detectedDueDatePhrase ?? detectedNotesDueDatePhrase
    }

    private var resolvedDueDate: CivilDate? {
        activeDueDatePhrase?.resolvedDueDate(selectedDate: selectedDueDate) ?? selectedDueDate
    }

    private var resolvedDueTime: CivilTime? {
        activeDueDatePhrase?.dueTime ?? selectedDueTime
    }

    private var dueDateHelpText: String {
        if let activeDueDatePhrase {
            return "The detected phrases set \(resolvedDueDate?.rawValue ?? activeDueDatePhrase.dueDate.rawValue)\(resolvedDueTime.map { " at \($0.rawValue)" } ?? "") when saved. A time-only phrase keeps your selected calendar date."
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

private struct TaskEditorClassificationFields: View {
    @Binding var projectsText: String
    @Binding var tagsText: String
    let projectChoices: [String]
    let tagChoices: [String]
    let detectedProjects: [String]
    let detectedTags: [String]

    var body: some View {
        let selectedProjects = Set(TaskEditorDraft.parseCommaSeparated(projectsText))
        let matchingTags = matchingTagChoices
        TextField("Projects", text: $projectsText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("Projects, separated by commas")
        if !projectChoices.isEmpty {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(projectChoices, id: \.self) { project in
                        projectChoice(project, selectedProjects: selectedProjects)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityLabel("Project choices")
        }
        if !detectedProjects.isEmpty {
            Text("Mentioned projects are included automatically. Edit #mentions in the name or notes to change them; existing project assignments are kept.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        TextField("Tags", text: $tagsText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("Tags, separated by commas")
            .accessibilityIdentifier("task-editor-tags")
        if !matchingTags.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(matchingTags, id: \.self) { tag in
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
        if !detectedTags.isEmpty {
            Text("Mentioned tags are included automatically. Edit @mentions in the name or notes to change them; existing tag assignments are kept.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        Text("Projects and tags are comma-separated. Use #project and @tag in the name or notes for automatic assignment.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func projectChoice(_ project: String, selectedProjects: Set<String>) -> some View {
        let isDetected = detectedProjects.contains(project)
        let isSelected = isDetected || selectedProjects.contains(project)
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
        .accessibilityHint(isDetected ? "Assigned by a #mention in the name or notes." : "")
        .disabled(isDetected)
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
}

private struct TaskEditorScheduleFields: View {
    let isNewTask: Bool
    @Binding var hasDueDate: Bool
    @Binding var hasDueTime: Bool
    @Binding var dueDate: Date
    @Binding var hasPendingRelativeDueDate: Bool
    @Binding var saveError: String?
    @Binding var recurrence: String?
    @Binding var recurrenceFrom: RecurrenceFrom?
    @Binding var recurrenceRule: RecurrenceRule?
    @Binding var recurrenceError: String?
    let initialRecurrenceSettings: TaskRecurrenceFields.Settings
    let helpText: String

    var body: some View {
        if isNewTask {
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
        Text(helpText)
            .font(.footnote)
            .foregroundStyle(.secondary)
        TaskRecurrenceFields(
            recurrence: $recurrence,
            recurrenceFrom: $recurrenceFrom,
            parsedRule: $recurrenceRule,
            validationError: $recurrenceError,
            initialSettings: initialRecurrenceSettings
        )
    }
}

private struct TaskEditorLinkFields: View {
    @Binding var url: String?
    let onFocus: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            TextField("Add link…", text: Binding(
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
        HStack(spacing: 12) {
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
            Button(action: add) {
                Label("Add subtask", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("task-editor-subtask-add")
            .disabled(!canAdd)
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
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                    Text(frequency.editorTitle).tag(Optional(frequency))
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
                            value: settings.weekdays.isEmpty ? String(localized: "Anchor weekday", locale: locale) :
                                RecurrenceWeekday.allCases.filter { settings.weekdays.contains($0) }
                                    .map { weekdayName($0) }.formatted(.list(type: .and).locale(locale))
                        )
                    }
                    .accessibilityIdentifier("task-editor-repeat-weekdays")
                }

                if frequency == .monthly || frequency == .yearly {
                    Menu {
                        ForEach(1 ... 31, id: \.self) { day in
                            Toggle(isOn: selection(day, in: $settings.monthDays)) {
                                Text(day, format: .number)
                            }
                            .accessibilityIdentifier("task-editor-repeat-month-day-\(day)")
                        }
                    } label: {
                        selectionLabel(
                            "Days of month",
                            value: settings.monthDays.isEmpty ? String(localized: "Anchor day", locale: locale) :
                                settings.monthDays.sorted().map { $0.formatted(.number.locale(locale)) }
                                    .formatted(.list(type: .and).locale(locale))
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
                            value: settings.months.isEmpty ? String(localized: "Anchor month", locale: locale) :
                                settings.months.sorted().map { monthName($0) }
                                    .formatted(.list(type: .and).locale(locale))
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
                    if settings.anchor == .schedule {
                        Text("Completing an occurrence keeps the original schedule and skips missed dates. A due date matching any selections is required. Empty selections use the anchor date. Impossible dates are skipped, never shortened. Choose a terminal State to finish the series without scheduling another occurrence.")
                    } else {
                        Text("Completing an occurrence starts the interval from the day you complete it. A due date matching any selections is required. Empty selections use the anchor date. Impossible dates are skipped, never shortened. Choose a terminal State to finish the series without scheduling another occurrence.")
                    }
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

    private func selectionLabel(_ title: LocalizedStringKey, value: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout())
        return layout {
            Text(title).foregroundStyle(.primary)
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func intervalUnit(for frequency: RecurrenceFrequency) -> LocalizedStringKey {
        switch frequency {
        case .daily: "day(s)"
        case .weekly: "week(s)"
        case .monthly: "month(s)"
        case .yearly: "year(s)"
        }
    }

    private func weekdayName(_ weekday: RecurrenceWeekday) -> String {
        let index: Int
        switch weekday {
        case .sunday: index = 0
        case .monday: index = 1
        case .tuesday: index = 2
        case .wednesday: index = 3
        case .thursday: index = 4
        case .friday: index = 5
        case .saturday: index = 6
        }
        return displayCalendar.weekdaySymbols[index]
    }

    private func monthName(_ month: Int) -> String {
        displayCalendar.monthSymbols[month - 1]
    }

    private var displayCalendar: Calendar {
        var calendar = TaskSchedule.calendar
        calendar.locale = locale
        return calendar
    }
}

private extension RecurrenceFrequency {
    var editorTitle: LocalizedStringResource {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }
}
