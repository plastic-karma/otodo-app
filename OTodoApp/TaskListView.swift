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
        let displayedTasks = visibleTasks
        let today = currentDateKey

        return ZStack(alignment: .leading) {
            NavigationStack {
                ZStack {
                    OTodoCanvas()

                    List {
                        Section {
                            workspaceHero(taskCount: displayedTasks.count)
                                .listRowInsets(
                                    EdgeInsets(top: 8, leading: 16, bottom: 6, trailing: 16)
                                )
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }

                        Section {
                            Picker("Todo visibility", selection: $visibility) {
                                ForEach(TaskVisibility.allCases, id: \.self) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(5)
                            .background(
                                .thinMaterial,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .accessibilityIdentifier("task-filter")
                            .listRowInsets(
                                EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16)
                            )
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }

                        if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
                            Section {
                                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        Color.red.opacity(0.09),
                                        in: RoundedRectangle(
                                            cornerRadius: 16,
                                            style: .continuous
                                        )
                                    )
                                    .accessibilityLabel("Error. \(errorMessage)")
                                    .listRowInsets(
                                        EdgeInsets(
                                            top: 4,
                                            leading: 16,
                                            bottom: 4,
                                            trailing: 16
                                        )
                                    )
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                        }

                        Section {
                            if model.isBusy && model.tasks.isEmpty {
                                loadingRow
                            } else if displayedTasks.isEmpty {
                                emptyRow
                            } else {
                                ForEach(displayedTasks, id: \.id) { task in
                                    Button {
                                        editorPresentation = .edit(task)
                                    } label: {
                                        TaskRowView(
                                            task: task,
                                            workflowState: state(for: task.state),
                                            today: today
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Opens the todo editor")
                                    .accessibilityIdentifier(
                                        "task-row-\(task.id.rawValue)"
                                    )
                                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                        if state(for: task.state)?.isTerminal != true,
                                           completionState != nil
                                        {
                                            Button {
                                                complete(task)
                                            } label: {
                                                Label("Done", systemImage: "checkmark")
                                            }
                                            .tint(OTodoTheme.mint)
                                            .disabled(model.isBusy)
                                            .accessibilityIdentifier(
                                                "task-complete-\(task.id.rawValue)"
                                            )
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
                                        .accessibilityIdentifier(
                                            "task-delete-\(task.id.rawValue)"
                                        )
                                    }
                                    .listRowInsets(
                                        EdgeInsets(
                                            top: 5,
                                            leading: 16,
                                            bottom: 5,
                                            trailing: 16
                                        )
                                    )
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                }
                            }

                            SyncStatusView(model: model)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    .thinMaterial,
                                    in: RoundedRectangle(
                                        cornerRadius: 14,
                                        style: .continuous
                                    )
                                )
                                .listRowInsets(
                                    EdgeInsets(
                                        top: 12,
                                        leading: 16,
                                        bottom: 6,
                                        trailing: 16
                                    )
                                )
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        } header: {
                            taskSectionHeader(count: displayedTasks.count)
                        }
                        .listSectionSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .listSectionSpacing(10)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.top, 2, for: .scrollContent)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear
                            .frame(height: 72)
                            .accessibilityHidden(true)
                    }
                    .accessibilityIdentifier("task-list")
                    .refreshable {
                        await model.refresh()
                    }
                    .overlay(alignment: .bottomTrailing) {
                        addTodoButton
                            .padding(.trailing, 20)
                            .padding(.bottom, 18)
                    }
                }
                .navigationTitle(selectedProject.map(projectDisplayName) ?? "Todos")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isProjectSidebarPresented = true
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .font(.body.weight(.semibold))
                        }
                        .accessibilityLabel("Projects")
                        .accessibilityHint("Shows project filters")
                        .accessibilityIdentifier("project-sidebar-toggle")
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
                    Color.black.opacity(0.32)
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

    private func workspaceHero(taskCount: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            OTodoTheme.heroGradient

            Image(systemName: heroSymbol)
                .font(.system(size: 104, weight: .bold))
                .foregroundStyle(.white.opacity(0.10))
                .offset(x: 24, y: -22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(heroEyebrow, systemImage: heroSymbol)
                        .font(.caption.weight(.bold))
                        .tracking(0.8)

                    Spacer()

                    Text("\(taskCount) \(taskCount == 1 ? "todo" : "todos")")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.16), in: Capsule())
                }

                Text(heroTitle)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))

                Text(heroSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
            }
            .foregroundStyle(.white)
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .bottomLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: OTodoTheme.accent.opacity(0.22), radius: 18, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workspace-hero")
    }

    private func taskSectionHeader(count: Int) -> some View {
        HStack {
            Text(visibility == .today ? "Your focus" : "\(visibility.rawValue) todos")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            Text("\(count)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(OTodoTheme.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(OTodoTheme.accent.opacity(0.10), in: Capsule())
        }
        .padding(.horizontal, 4)
        .textCase(nil)
    }

    private var addTodoButton: some View {
        Button {
            guard model.configuration != nil else { return }
            editorPresentation = .create
        } label: {
            Image(systemName: "plus")
                .font(.title2.bold())
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(OTodoTheme.heroGradient, in: Circle())
                .shadow(color: OTodoTheme.accent.opacity(0.34), radius: 12, y: 7)
        }
        .disabled(model.configuration == nil)
        .opacity(model.configuration == nil ? 0.45 : 1)
        .accessibilityLabel("Add Todo")
        .accessibilityIdentifier("task-add")
    }

    private var heroTitle: String {
        if let selectedProject {
            return projectDisplayName(selectedProject)
        }
        switch visibility {
        case .today:
            return "Today"
        case .active:
            return "In Motion"
        case .all:
            return "All Todos"
        }
    }

    private var heroEyebrow: String {
        selectedProject == nil ? "YOUR FOCUS" : "PROJECT"
    }

    private var heroSymbol: String {
        if selectedProject != nil {
            return "folder.fill"
        }
        switch visibility {
        case .today:
            return "sun.max.fill"
        case .active:
            return "bolt.fill"
        case .all:
            return "tray.full.fill"
        }
    }

    private var heroSubtitle: String {
        if selectedProject != nil {
            return "\(visibility.rawValue) view · clear the next meaningful step"
        }
        switch visibility {
        case .today:
            return Date.now.formatted(
                .dateTime.weekday(.wide).month(.wide).day()
            )
        case .active:
            return "Everything still in motion"
        case .all:
            return "The complete picture, finished work included"
        }
    }

    private var projectSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.title3.bold())
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Projects")
                        .font(.title2.bold())
                    Text("Choose what deserves your focus")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                }

                Spacer(minLength: 8)

                Button("Close", systemImage: "xmark") {
                    dismissProjectSidebar()
                }
                .labelStyle(.iconOnly)
                .font(.body.bold())
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.14), in: Circle())
                .accessibilityIdentifier("project-sidebar-close")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 22)
            .background(OTodoTheme.heroGradient)

            ScrollView {
                LazyVStack(spacing: 8) {
                    projectFilterButton(nil)

                    ForEach(model.projectChoices, id: \.self) { project in
                        projectFilterButton(project)
                    }
                }
                .padding(14)
            }

            Divider()

            Button {
                dismissProjectSidebar()
                isProjectEditorPresented = true
            } label: {
                Label("New Project", systemImage: "folder.badge.plus")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.configuration == nil || model.isBusy)
            .accessibilityIdentifier("project-add")
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Button {
                dismissProjectSidebar()
                Task { @MainActor in
                    await model.signOut()
                }
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.isBusy)
            .accessibilityIdentifier("sign-out")
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 316)
        .frame(maxHeight: .infinity)
        .background(OTodoTheme.card)
        .shadow(color: .black.opacity(0.24), radius: 24, x: 10)
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
        let color = projectColor(project)

        return Button {
            selectedProject = project
            dismissProjectSidebar()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: project == nil ? "tray.full.fill" : "folder.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 38, height: 38)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

                Text(title)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? OTodoTheme.accent : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.primary.opacity(0.055), in: Capsule())

                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(OTodoTheme.accent)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
            .background(
                isSelected ? OTodoTheme.accent.opacity(0.11) : Color.clear,
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(OTodoTheme.accent.opacity(0.15))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) todos")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityIdentifier(project.map { "project-filter-\($0)" } ?? "project-filter-all")
    }

    private func projectColor(_ project: String?) -> Color {
        guard let project else { return OTodoTheme.accent }
        let paletteIndex = project.utf8.reduce(0) { ($0 + Int($1)) % 4 }
        switch paletteIndex {
        case 0:
            return OTodoTheme.violet
        case 1:
            return OTodoTheme.coral
        case 2:
            return OTodoTheme.gold
        default:
            return OTodoTheme.mint
        }
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
        HStack(spacing: 12) {
            ProgressView()
                .tint(OTodoTheme.accent)
            Text("Gathering your todos…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            OTodoTheme.raisedCard,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var emptyRow: some View {
        VStack(spacing: 14) {
            Image(systemName: visibility == .all ? "checklist" : "checkmark")
                .font(.title2.bold())
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(OTodoTheme.heroGradient, in: Circle())
                .shadow(color: OTodoTheme.accent.opacity(0.2), radius: 9, y: 5)

            Text("No \(visibility.rawValue) Todos")
                .font(.title3.bold())

            Text(emptyDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if model.configuration != nil {
                Button("Add a Todo") {
                    editorPresentation = .create
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(
            OTodoTheme.raisedCard,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.045))
        }
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        .listRowSeparator(.hidden)
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
