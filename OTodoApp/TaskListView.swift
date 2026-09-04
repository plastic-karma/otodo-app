import Foundation
import OTodoCore
import SwiftUI

struct TaskListView: View {
    @Bindable private var model: AppModel
    @State private var editorPresentation: EditorPresentation?
    @State private var visibility = TaskVisibility.today
    @State private var selectedProject: String?
    @State private var isProjectSidebarPresented = false
    @State private var isProjectEditorPresented = false

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        ZStack(alignment: .leading) {
            NavigationStack {
            List {

                Section {
                    Picker("Todo visibility", selection: $visibility) {
                        ForEach(TaskVisibility.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
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
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if state(for: task.state)?.isTerminal != true,
                                   completionState != nil
                                {
                                    Button {
                                        complete(task)
                                    } label: {
                                        Label("Done", systemImage: "checkmark")
                                    }
                                    .tint(.green)
                                    .disabled(model.isBusy)
                                    .accessibilityIdentifier("task-complete-\(task.id.rawValue)")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { @MainActor in
                                        await model.deleteTask(task)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .disabled(model.isBusy)
                                .accessibilityIdentifier("task-delete-\(task.id.rawValue)")
                            }
                        }
                    }
                } header: {
                    Text("\(visibility.rawValue) Todos")
                } footer: {
                    SyncStatusView(model: model)
                }
            }
            .accessibilityIdentifier("task-list")
            .refreshable {
                await model.refresh()
            }
            .navigationTitle(selectedProject.map(projectDisplayName) ?? "Todos")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Projects", systemImage: "line.3.horizontal") {
                        isProjectSidebarPresented = true
                    }
                    .accessibilityHint("Shows project filters")
                    .accessibilityIdentifier("project-sidebar-toggle")
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
                        projectChoices: model.projectChoices,
                        tagChoices: model.tagChoices
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
            .allowsHitTesting(!isProjectSidebarPresented)
            .accessibilityHidden(isProjectSidebarPresented)
            .onChange(of: model.projectChoices) { _, projects in
                if let selectedProject, !projects.contains(selectedProject) {
                    self.selectedProject = nil
                }
            }

            if isProjectSidebarPresented {
                Button {
                    dismissProjectSidebar()
                } label: {
                    Color.black.opacity(0.24)
                        .ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close projects")

                projectSidebar
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.snappy(duration: 0.24), value: isProjectSidebarPresented)
        .sheet(isPresented: $isProjectEditorPresented) {
            if let configuration = model.configuration {
                ProjectEditorView(
                    existingSlugs: model.projectChoices,
                    projectsDirectory: configuration.projectsDirectory
                ) { title, slug in
                    await model.createProject(title: title, slug: slug)
                    guard model.errorMessage == nil else {
                        return model.errorMessage
                    }
                    selectedProject = slug
                    return nil
                }
                .presentationDetents([.medium])
            } else {
                ContentUnavailableView(
                    "Todo configuration unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Close the editor and refresh the workspace.")
                )
            }
        }
    }

    private var projectSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Projects")
                        .font(.title2.bold())
                    Text("Choose what to focus on")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Close", systemImage: "xmark.circle.fill") {
                    dismissProjectSidebar()
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("project-sidebar-close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            Divider()

            ScrollView {
                LazyVStack(spacing: 6) {
                    projectFilterButton(nil)

                    ForEach(model.projectChoices, id: \.self) { project in
                        projectFilterButton(project)
                    }
                }
                .padding(12)
            }

            Divider()

            Button {
                dismissProjectSidebar()
                isProjectEditorPresented = true
            } label: {
                Label("New Project", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.configuration == nil || model.isBusy)
            .accessibilityIdentifier("project-add")
            .padding(20)

            Divider()

            Button {
                dismissProjectSidebar()
                Task { @MainActor in
                    await model.signOut()
                }
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .accessibilityIdentifier("sign-out")
            .padding(20)
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .shadow(color: .black.opacity(0.18), radius: 20, x: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-sidebar")
        .accessibilityAction(.escape) {
            dismissProjectSidebar()
        }
    }

    private func projectFilterButton(_ project: String?) -> some View {
        let isSelected = selectedProject == project
        let title = project.map(projectDisplayName) ?? "All Todos"
        let count = project.map(taskCount(for:)) ?? model.tasks.count

        return Button {
            selectedProject = project
            dismissProjectSidebar()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: project == nil ? "tray.full" : "folder")
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)

                Text(title)
                    .font(.body.weight(isSelected ? .semibold : .regular))

                Spacer()

                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) todos")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityIdentifier(project.map { "project-filter-\($0)" } ?? "project-filter-all")
    }

    private func taskCount(for project: String) -> Int {
        model.tasks.lazy.filter { $0.projectSlugs.contains(project) }.count
    }

    private func projectDisplayName(_ project: String) -> String {
        project.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private func dismissProjectSidebar() {
        isProjectSidebarPresented = false
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
                "No \(visibility.rawValue) Todos",
                systemImage: visibility == .all ? "checklist" : "checkmark.circle"
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
        let projectScope = selectedProject.map {
            " in \(projectDisplayName($0))"
        } ?? ""
        switch visibility {
        case .today:
            return "No active todos\(projectScope) are due today or overdue."
        case .active:
            return "No active todos\(projectScope). Choose All to see terminal todos."
        case .all:
            return selectedProject.map {
                "No todos in \(projectDisplayName($0)) yet."
            } ?? "Add a todo to get started."
        }
    }

    private var visibleTasks: [TodoTask] {
        let states = model.configuration?.states ?? []
        let stateOrder = Dictionary(uniqueKeysWithValues: states.enumerated().map { ($0.element.id, $0.offset) })
        let terminalStates = Set(states.lazy.filter(\.isTerminal).map(\.id))
        let today = currentDateKey

        return model.tasks
            .filter { task in
                if let selectedProject,
                   !task.projectSlugs.contains(selectedProject)
                {
                    return false
                }
                let isTerminal = terminalStates.contains(task.state)
                switch visibility {
                case .today:
                    return !isTerminal && task.dueDate.map { $0.rawValue <= today } == true
                case .active:
                    return !isTerminal
                case .all:
                    return true
                }
            }
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

    private var completionState: WorkflowState? {
        let states = model.configuration?.states ?? []
        return states.first(where: { $0.id == "done" && $0.isTerminal })
            ?? states.first(where: \.isTerminal)
    }

    private var currentDateKey: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month, .day], from: .now)
        return String(
            format: "%04d-%02d-%02d",
            components.year!,
            components.month!,
            components.day!
        )
    }

    private func complete(_ task: TodoTask) {
        guard let completionState else { return }
        var draft = TaskEditorDraft(task: task)
        draft.state = completionState.id
        Task { @MainActor in
            await model.updateTask(id: task.id, draft: draft)
        }
    }

    private func state(for id: String) -> WorkflowState? {
        model.configuration?.states.first(where: { $0.id == id })
    }
}

private enum TaskVisibility: String, CaseIterable, Hashable {
    case today = "Today"
    case active = "Active"
    case all = "All"
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
