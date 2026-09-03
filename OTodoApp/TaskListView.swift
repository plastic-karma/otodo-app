import OTodoCore
import SwiftUI

struct TaskListView: View {
    @Bindable private var model: AppModel
    @State private var editorPresentation: EditorPresentation?

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SyncStatusView(model: model)
                }

                Section {
                    Picker("Todo visibility", selection: $model.showCompleted) {
                        Text("Active").tag(false)
                        Text("All").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("task-filter")
                }

                if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error. \(errorMessage)")
                    }
                }

                Section {
                    if model.isBusy && model.tasks.isEmpty {
                        loadingRow
                    } else if visibleTasks.isEmpty {
                        emptyRow
                    } else {
                        ForEach(visibleTasks, id: \.id) { task in
                            Button {
                                editorPresentation = .edit(task)
                            } label: {
                                TaskRowView(
                                    task: task,
                                    workflowState: state(for: task.state)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the todo editor")
                            .accessibilityIdentifier("task-row-\(task.id.rawValue)")
                        }
                    }
                } header: {
                    Text(model.showCompleted ? "All Todos" : "Active Todos")
                }
            }
            .accessibilityIdentifier("task-list")
            .refreshable {
                await model.refresh()
            }
            .navigationTitle("Todos")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                        Task { @MainActor in
                            await model.signOut()
                        }
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("sign-out")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button("Add Todo", systemImage: "plus") {
                        guard model.configuration != nil else { return }
                        editorPresentation = .create
                    }
                    .disabled(model.configuration == nil)
                    .accessibilityIdentifier("task-add")
                }
            }
            .sheet(item: $editorPresentation) { presentation in
                if let configuration = model.configuration {
                    TaskEditorView(
                        draft: presentation.draft(configuration: configuration),
                        configuration: configuration,
                        projectChoices: model.projectChoices
                    ) { value in
                        switch presentation {
                        case .create:
                            await model.createTask(draft: value)
                        case let .edit(task):
                            await model.updateTask(id: task.id, draft: value)
                        }
                        return model.errorMessage
                    }
                    .presentationDetents([.large])
                } else {
                    ContentUnavailableView(
                        "Todo configuration unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Close the editor and refresh the workspace.")
                    )
                }
            }
        }
    }

    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView("Loading todos")
            Spacer()
        }
        .padding(.vertical, 32)
        .listRowBackground(Color.clear)
    }

    private var emptyRow: some View {
        ContentUnavailableView {
            Label(
                model.showCompleted ? "No Todos" : "No Active Todos",
                systemImage: model.showCompleted ? "checklist" : "checkmark.circle"
            )
        } description: {
            Text(emptyDescription)
        } actions: {
            if model.configuration != nil {
                Button("Add Todo") {
                    editorPresentation = .create
                }
            }
        }
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
    }

    private var emptyDescription: String {
        if model.tasks.isEmpty {
            return "Add a todo to get started. Changes are saved locally when offline."
        }
        return "Terminal todos are hidden. Choose All to see them."
    }

    private var visibleTasks: [TodoTask] {
        let states = model.configuration?.states ?? []
        let stateOrder = Dictionary(uniqueKeysWithValues: states.enumerated().map { ($0.element.id, $0.offset) })
        let terminalStates = Set(states.lazy.filter(\.isTerminal).map(\.id))

        return model.tasks
            .filter { model.showCompleted || !terminalStates.contains($0.state) }
            .sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }

                let lhsStateIndex = stateOrder[lhs.state] ?? Int.max
                let rhsStateIndex = stateOrder[rhs.state] ?? Int.max
                if lhsStateIndex != rhsStateIndex {
                    return lhsStateIndex < rhsStateIndex
                }

                let lhsName = lhs.name.utf8
                let rhsName = rhs.name.utf8
                if !lhsName.elementsEqual(rhsName) {
                    return lhsName.lexicographicallyPrecedes(rhsName)
                }
                return lhs.id < rhs.id
            }
    }


    private func state(for id: String) -> WorkflowState? {
        model.configuration?.states.first(where: { $0.id == id })
    }
}

private enum EditorPresentation: Identifiable {
    case create
    case edit(TodoTask)

    var id: String {
        switch self {
        case .create:
            return "create"
        case let .edit(task):
            return "edit-\(task.id.rawValue)"
        }
    }

    func draft(configuration: StoreConfiguration) -> TaskEditorDraft {
        switch self {
        case .create:
            return TaskEditorDraft(configuration: configuration)
        case let .edit(task):
            return TaskEditorDraft(task: task)
        }
    }
}
