import Foundation
import OTodoCore
import SwiftUI

struct TaskSearchView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel

    @State private var query = ""
    @State private var index: TaskSearchIndex?
    @State private var editorPresentation: EditorPresentation?
    @State private var reschedulePresentation: ReschedulePresentation?

    var body: some View {
        NavigationStack {
            let results = index?.tasks(matching: query) ?? []
            List {
                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, index != nil {
                    Section {
                        ForEach(results, id: \.id) { task in
                            searchRow(task)
                        }
                    } header: {
                        Text("\(results.count) \(results.count == 1 ? "result" : "results") · Entire workspace")
                    }
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("task-search-results")
            .overlay {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "Search all todos", systemImage: "magnifyingglass",
                        description: Text("Find names, notes, tags, and projects. Completed todos and subtasks are included.")
                    )
                    .allowsHitTesting(false)
                } else if index == nil {
                    ProgressView("Preparing search")
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .accessibilityIdentifier("task-search-empty")
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search all todos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", role: .cancel) { dismiss() }
                        .accessibilityIdentifier("task-search-close")
                }
            }
            .task(id: searchInput) {
                let input = searchInput
                index = nil
                let worker = Task.detached(priority: .userInitiated) {
                    TaskSearchIndex(tasks: input.tasks, projects: input.projects)
                }
                let updated = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                index = updated
            }
            .sheet(item: $editorPresentation) { presentation in
                if let configuration = model.configuration {
                    TaskEditorView(
                        draft: presentation.draft,
                        configuration: configuration,
                        projectChoices: model.projectChoices,
                        tagChoices: model.tagChoices,
                        hierarchy: model.hierarchy,
                        workspaceTasks: model.tasks,
                        attachmentModel: model
                    ) { draft in
                        switch presentation {
                        case .create:
                            await model.createTask(draft: draft)
                        case let .edit(task):
                            await model.updateTask(id: task.id, draft: draft)
                        }
                        return model.errorMessage
                    }
                    .id(presentation.id)
                    .presentationDetents([.large])
                }
            }
            .sheet(item: $reschedulePresentation) { presentation in
                TaskRescheduleView(tasks: presentation.tasks) { date, time in
                    await model.rescheduleTasks(presentation.tasks, dueDate: date, dueTime: time)
                    return model.errorMessage
                }
                .presentationDetents([.large])
            }
        }
    }

    private var searchInput: SearchInput {
        SearchInput(tasks: model.tasks, projects: model.projectDetails, workspace: model.workspaceSelection)
    }

    private func searchRow(_ task: TodoTask) -> some View {
        let state = model.configuration?.states.first { $0.id == task.state }
        return VStack(alignment: .leading, spacing: 0) {
            TaskRowView(
                task: task, workflowState: state, today: TodayWidgetSnapshotBuilder.dateKey(for: .now),
                isCompletionDisabled: model.isBusy || TaskRowActions.completionTarget(for: task, in: model) == nil,
                onOpen: { editorPresentation = .edit(task) },
                onToggleCompletion: { TaskRowActions.toggleCompletion(task, in: model) },
                ancestry: ancestry(for: task)
            )
            if state?.isTerminal == true || task.parentID != nil {
                HStack(spacing: 12) {
                    if state?.isTerminal == true {
                        Label(state?.name ?? task.state, systemImage: "checkmark.circle")
                    }
                    if task.parentID != nil {
                        Label("Subtask", systemImage: "arrow.turn.down.right")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 44)
                .padding(.bottom, 10)
            }
        }
        .modifier(TaskRowActions(
            task: task, model: model,
            onAddSubtask: {
                guard let configuration = model.configuration else { return }
                var draft = TaskEditorDraft(configuration: configuration)
                draft.projectSlugs = task.projectSlugs
                draft.parentID = task.id
                editorPresentation = .create(draft, id: UUID())
            },
            onReschedule: { reschedulePresentation = ReschedulePresentation(tasks: [task]) }
        ))
    }

    private func ancestry(for task: TodoTask) -> String? {
        guard let parentID = task.parentID else { return nil }
        guard model.hierarchy.task(for: parentID) != nil else {
            return "Missing parent · \(parentID.rawValue)"
        }
        let names = model.hierarchy.ancestorIDs(of: task.id).map {
            model.hierarchy.task(for: $0)?.name ?? $0.rawValue
        }
        return "Parent: \(names.joined(separator: " › "))"
    }
}

private struct SearchInput: Equatable, Sendable {
    let tasks: [TodoTask]
    let projects: [String: TodoProject]
    let workspace: WorkspaceSelection?
}
