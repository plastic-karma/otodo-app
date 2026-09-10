import OTodoCore
import SwiftUI

/// One action surface for task lists and saved subtasks in an editor.
@MainActor
struct TaskRowActions: ViewModifier {
    let task: TodoTask
    let model: AppModel
    var isSelecting = false
    let onAddSubtask: () -> Void
    let onReschedule: () -> Void

    private var canComplete: Bool {
        model.configuration?.states.first(where: { $0.id == task.state })?.isTerminal != true
            && Self.completionTarget(for: task, in: model) != nil
    }

    private var progressTarget: WorkflowState? {
        guard let configuration = model.configuration,
              let current = configuration.states.first(where: { $0.id == task.state }),
              !current.isTerminal,
              let inProgress = configuration.states.first(where: \.isInProgress)
        else { return nil }
        if current.isInProgress {
            guard configuration.defaultState != inProgress.id else { return nil }
            return configuration.states.first(where: { $0.id == configuration.defaultState })
        }
        return inProgress
    }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if !isSelecting {
                    Button(action: onAddSubtask) {
                        Label("Add Subtask", systemImage: "arrow.turn.down.right")
                    }
                    .disabled(model.isBusy || model.configuration?.schemaVersion != 2)
                    .accessibilityIdentifier("task-context-add-subtask-\(task.id.rawValue)")
                    if canComplete {
                        Button { Self.toggleCompletion(task, in: model) } label: {
                            Label(task.recurrence == nil ? "Done" : "Complete occurrence", systemImage: "checkmark")
                        }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("task-context-complete-\(task.id.rawValue)")
                    }
                    if let target = progressTarget {
                        Button { setState(target.id) } label: {
                            Label(
                                target.isInProgress ? "Start" : "Move to \(target.name)",
                                systemImage: target.isInProgress ? "play.fill" : "arrow.uturn.backward"
                            )
                        }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier(
                            "task-context-\(target.isInProgress ? "start" : "reset-state")-\(task.id.rawValue)"
                        )
                    }
                    if canComplete, task.recurrence != nil {
                        Button(action: finishSeries) {
                            Label("Finish series", systemImage: "stop.circle")
                        }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("task-context-finish-series-\(task.id.rawValue)")
                    }
                    Button(action: onReschedule) {
                        Label("Reschedule", systemImage: "calendar.badge.clock")
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("task-context-reschedule-\(task.id.rawValue)")
                    Divider()
                    Button(role: .destructive) { Task { await model.deleteTask(task) } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("task-context-delete-\(task.id.rawValue)")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !isSelecting {
                    if canComplete {
                        Button { Self.toggleCompletion(task, in: model) } label: {
                            Label(task.recurrence == nil ? "Done" : "Complete occurrence", systemImage: "checkmark")
                        }
                        .tint(OTodoTheme.mint)
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("task-complete-\(task.id.rawValue)")
                    }
                    Button(action: onAddSubtask) {
                        Label("Add Subtask", systemImage: "arrow.turn.down.right")
                    }
                    .tint(OTodoTheme.accent)
                    .disabled(model.isBusy || model.configuration?.schemaVersion != 2)
                    .accessibilityIdentifier("task-add-subtask-\(task.id.rawValue)")
                    Button(action: onReschedule) {
                        Label("Reschedule", systemImage: "calendar.badge.clock")
                    }
                    .tint(OTodoTheme.filledViolet)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("task-reschedule-\(task.id.rawValue)")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if !isSelecting {
                    Button(role: .destructive) { Task { await model.deleteTask(task) } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("task-delete-\(task.id.rawValue)")
                }
            }
    }

    static func completionTarget(for task: TodoTask, in model: AppModel) -> String? {
        guard let configuration = model.configuration else { return nil }
        if configuration.states.first(where: { $0.id == task.state })?.isTerminal == true {
            return configuration.defaultState
        }
        return (configuration.states.first(where: { $0.id == "done" && $0.isTerminal })
            ?? configuration.states.first(where: \.isTerminal))?.id
    }

    static func toggleCompletion(_ task: TodoTask, in model: AppModel) {
        guard let targetState = completionTarget(for: task, in: model) else { return }
        Task { @MainActor in
            guard !model.isBusy else { return }
            if model.configuration?.states.first(where: { $0.id == task.state })?.isTerminal == true {
                var draft = TaskEditorDraft(task: task)
                draft.state = targetState
                await model.updateTask(id: task.id, draft: draft)
            } else {
                await model.completeTask(task)
            }
        }
    }

    private func finishSeries() {
        guard canComplete, task.recurrence != nil,
              let targetState = Self.completionTarget(for: task, in: model) else { return }
        setState(targetState)
    }

    private func setState(_ targetState: String) {
        Task { @MainActor in
            guard !model.isBusy else { return }
            var draft = TaskEditorDraft(task: task)
            draft.state = targetState
            await model.updateTask(id: task.id, draft: draft)
        }
    }
}
