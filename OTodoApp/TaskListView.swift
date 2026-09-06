import Foundation
import OTodoCore
import SwiftUI
import UIKit

struct TaskListView: View {
    @EnvironmentObject private var quickActions: QuickActionSceneDelegate
    @Environment(\.scenePhase) private var scenePhase

    @Bindable private var model: AppModel
    private let notifications: TaskNotificationManager
    @State private var editorPresentation: EditorPresentation?
    @State private var filterLibrary: TaskFilterLibrary
    @State private var selectedFilterID = "today"
    @State private var isFilterLibraryPresented = false
    @State private var displayedTasks: [TodoTask] = []
    @State private var isFiltering = false
    @State private var filterError: String?
    @State private var selectedProject: String?
    @State private var isProjectSidebarPresented = false
    @State private var isProjectEditorPresented = false
    @State private var isChangelogPresented = false
    @State private var isBulkEditorPresented = false
    @State private var reschedulePresentation: ReschedulePresentation?
    @State private var isUpcoming = false
    @State private var agendaSections: [TaskAgendaSection] = []
    @State private var dates = TaskDateContext()
    @State private var isSelecting = false
    @State private var selectedTaskIDs: Set<TaskID> = []

    init(model: AppModel, notifications: TaskNotificationManager) {
        self.model = model
        self.notifications = notifications
        _filterLibrary = State(initialValue: TaskFilterLibrary(store: model.filterStore))
    }

    var body: some View {
        let input = filterInput

        return ZStack(alignment: .leading) {
            NavigationStack {
                ZStack {
                    OTodoCanvas()

                    List {
                        Section {
                            workspaceHeader(taskCount: displayedTasks.count)
                                .listRowInsets(
                                    EdgeInsets(top: 12, leading: 20, bottom: 10, trailing: 20)
                                )
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }

                        if filterLibrary.filters.contains(where: \.isStarred) {
                            Section {
                                favoriteFilters
                                    .listRowInsets(
                                        EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20)
                                    )
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                        }

                        if let message = filterError ?? filterLibrary.errorMessage {
                            Section {
                                Label(message, systemImage: "exclamationmark.triangle")
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                                    .accessibilityIdentifier("filter-error")
                            }
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

                        if model.isBusy && model.tasks.isEmpty {
                            Section { loadingRow }
                        } else if displayedTasks.isEmpty {
                            Section { emptyRow }
                        } else if isUpcoming {
                            ForEach(agendaSections, id: \.group) { section in
                                Section {
                                    if section.tasks.isEmpty {
                                        Text("No todos")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .listRowBackground(Color.clear)
                                    } else {
                                        ForEach(section.tasks, id: \.id) { task in
                                            taskRow(task)
                                        }
                                    }
                                } header: {
                                    agendaHeader(section)
                                }
                                .listSectionSeparator(.hidden)
                            }
                        } else {
                            Section {
                                ForEach(displayedTasks, id: \.id) { task in
                                    taskRow(task)
                                }
                            }
                            .listSectionSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .listSectionSpacing(10)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.top, 2, for: .scrollContent)
                    .accessibilityIdentifier("task-list")
                    .refreshable {
                        await model.refresh()
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 12) {
                            if isSelecting {
                                selectionActions
                            }
                            HStack(alignment: .bottom, spacing: 16) {
                                SyncStatusView(model: model)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if !isSelecting {
                                    addTodoButton
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 18)
                        .background(OTodoCanvas())
                    }
                }
                .navigationTitle(isUpcoming ? "Upcoming" : selectedProject.map(projectDisplayName) ?? "Todos")
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
                        .accessibilityHint("Shows Upcoming, Inbox, project filters, and changelog")
                        .accessibilityIdentifier("project-sidebar-toggle")
                    }
                    if isUpcoming {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(isSelecting ? "Cancel" : "Select") {
                                selectedTaskIDs.removeAll()
                                isSelecting.toggle()
                            }
                            .disabled(model.isBusy || (!isSelecting && (isFiltering || displayedTasks.isEmpty)))
                            .accessibilityIdentifier("upcoming-select")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Filters", systemImage: "line.3.horizontal.decrease") {
                            isFilterLibraryPresented = true
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("filters-open")
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
                .sheet(isPresented: $isBulkEditorPresented) {
                    TaskBulkEditorView { names in
                        await model.createTasks(names: names)
                        return model.errorMessage
                    }
                    .presentationDetents([.large])
                }
                .sheet(item: $reschedulePresentation) { presentation in
                    TaskRescheduleView(tasks: presentation.tasks) { date, time in
                        await model.rescheduleTasks(
                            presentation.tasks,
                            dueDate: date,
                            dueTime: time
                        )
                        if model.errorMessage == nil {
                            clearSelection()
                        }
                        return model.errorMessage
                    }
                    .presentationDetents([.large])
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
                    selectProject(slug)
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
        .sheet(isPresented: $isFilterLibraryPresented) {
            TaskFiltersView(
                library: filterLibrary,
                projectChoices: model.projectChoices,
                tagChoices: model.tagChoices
            ) { filter in
                selectFilter(filter.id)
                if !isUpcoming {
                    selectedProject = nil
                }
            }
        }
        .sheet(isPresented: $isChangelogPresented) {
            ChangelogView()
        }
        .task(id: model.workspaceSelection.map(FileWorkspaceStore.selectionKey(for:))) {
            selectedFilterID = "today"
            isUpcoming = false
            clearSelection()
            await filterLibrary.load(selection: model.workspaceSelection)
        }
        .task(id: input) {
            await updateVisibleTasks(input: input)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                .merge(
                    with: NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification),
                    NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
                )
                .receive(on: RunLoop.main)
        ) { _ in
            dates = TaskDateContext()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                dates = TaskDateContext()
            }
        }
        .onChange(of: filterLibrary.filters) { _, filters in
            if !filters.contains(where: { $0.id == selectedFilterID }) {
                selectedFilterID = "today"
            }
        }
        .onAppear(perform: presentPendingNewTodoRequest)
        .onChange(of: quickActions.pendingNewTodoRequestID) { _, _ in
            presentPendingNewTodoRequest()
        }
        .onChange(of: model.configuration) { _, _ in
            presentPendingNewTodoRequest()
        }

    }

    private var selectedFilter: SavedTaskFilter {
        filterLibrary.filters.first(where: { $0.id == selectedFilterID })
            ?? SavedTaskFilter.defaults[0]
    }

    private var favoriteFilters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(filterLibrary.filters.filter(\.isStarred)) { filter in
                    Button {
                        selectFilter(filter.id)
                    } label: {
                        Text(filter.name)
                            .font(.subheadline.weight(
                                selectedFilterID == filter.id ? .semibold : .regular
                            ))
                            .foregroundStyle(
                                selectedFilterID == filter.id ? OTodoTheme.accent : .secondary
                            )
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(
                                selectedFilterID == filter.id
                                    ? OTodoTheme.accent.opacity(0.08) : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("task-filter-\(filter.id)")
                    .accessibilityAddTraits(selectedFilterID == filter.id ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("task-filters")
    }

    private func selectFilter(_ id: String) {
        clearSelection()
        selectedFilterID = id
        if id == "inbox" {
            isUpcoming = false
            selectedProject = nil
        }
    }

    private func selectProject(_ project: String?) {
        clearSelection()
        if selectedFilterID == "inbox" {
            selectedFilterID = "active"
        }
        selectedProject = project
    }

    private func workspaceHeader(taskCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(workspaceTitle)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)

            Text(workspaceSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("\(taskCount) \(taskCount == 1 ? "todo" : "todos")")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workspace-header")
    }


    private var addTodoButton: some View {
        Menu {
            Button("New Todo", systemImage: "plus") {
                editorPresentation = .create
            }
            .accessibilityIdentifier("task-add-menu-todo")

            Button("Bulk Add", systemImage: "text.badge.plus") {
                isBulkEditorPresented = true
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("task-add-menu-bulk")

            Button("New Project", systemImage: "folder.badge.plus") {
                isProjectEditorPresented = true
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("project-add")
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.medium))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(OTodoTheme.filledAccent, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 5, y: 3)
        } primaryAction: {
            editorPresentation = .create
        }
        .menuOrder(.fixed)
        .disabled(model.configuration == nil)
        .opacity(model.configuration == nil ? 0.45 : 1)
        .accessibilityLabel("Add Todo")
        .accessibilityHint("Tap to add a todo; touch and hold for bulk entry or a project")
        .accessibilityIdentifier("task-add")
    }
    private func presentPendingNewTodoRequest() {
        guard model.configuration != nil,
              quickActions.consumePendingNewTodoRequest()
        else {
            return
        }
        isProjectSidebarPresented = false
        clearSelection()
        isProjectEditorPresented = false
        isFilterLibraryPresented = false
        isChangelogPresented = false
        isBulkEditorPresented = false
        reschedulePresentation = nil
        editorPresentation = .create
    }


    private var workspaceTitle: String {
        if isUpcoming {
            return selectedProject.map(projectDisplayName) ?? "Upcoming"
        }
        if let selectedProject {
            return projectDisplayName(selectedProject)
        }
        return selectedFilter.name
    }



    private var workspaceSubtitle: String {
        if isUpcoming {
            return selectedFilterID == "active"
                ? "Review deadlines and undated work"
                : "Upcoming · \(selectedFilter.name)"
        }
        if selectedProject != nil {
            return "\(selectedFilter.name) todos"
        }
        switch selectedFilter.id {
        case "today":
            return Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case "inbox":
            return "Active todos without a project"
        case "active":
            return "Todos still to do"
        case "all":
            return "Including completed todos"
        default:
            return selectedFilter.query
        }
    }

    private var projectSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projects")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                Button("Close", systemImage: "xmark") {
                    dismissProjectSidebar()
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .accessibilityIdentifier("project-sidebar-close")
            }
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    agendaModeButtons
                    inboxButton
                    projectFilterButton(nil)

                    ForEach(model.projectChoices, id: \.self) { project in
                        projectFilterButton(project)
                    }
                }
                .padding(14)
            }

            Divider()

            notificationControl

            Divider()
                .padding(.horizontal, 16)

            Button {
                dismissProjectSidebar()
                isChangelogPresented = true
            } label: {
                Label("Changelog", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("changelog-open")
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()
                .padding(.horizontal, 16)

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
        .frame(maxWidth: 316)
        .frame(maxHeight: .infinity)
        .background(OTodoTheme.card)
        .shadow(color: .black.opacity(0.12), radius: 16, x: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-sidebar")
        .accessibilityAction(.escape) {
            dismissProjectSidebar()
        }
    }

    private var notificationControl: some View {
        Button {
            Task { @MainActor in
                switch notifications.status {
                case .enabled:
                    await notifications.disable()
                case .denied:
                    guard let settingsURL = URL(
                        string: UIApplication.openSettingsURLString
                    ) else { return }
                    _ = await UIApplication.shared.open(settingsURL)
                case .checking:
                    break
                case .notRequested, .disabled:
                    await notifications.enable(
                        tasks: model.tasks,
                        states: model.configuration?.states ?? []
                    )
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: notificationIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(notificationColor)
                    .frame(width: 38, height: 38)
                    .background(
                        notificationColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 11)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Due reminders")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(notificationDetail)
                        .font(.caption)
                        .foregroundStyle(
                            notifications.errorMessage == nil ? Color.secondary : Color.red
                        )
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if notifications.isUpdating || notifications.status == .checking {
                    ProgressView()
                        .controlSize(.small)
                } else if notifications.isEnabled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(OTodoTheme.mint)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(notifications.isUpdating || notifications.status == .checking)
        .accessibilityLabel("Due reminders")
        .accessibilityValue(notificationAccessibilityValue)
        .accessibilityHint(notificationAccessibilityHint)
        .accessibilityIdentifier("notification-settings")
    }

    private var notificationDetail: String {
        if let errorMessage = notifications.errorMessage {
            return errorMessage
        }
        switch notifications.status {
        case .checking:
            return "Checking notification access"
        case .notRequested:
            return "Get an alert when a todo is due"
        case .enabled:
            return "Alerts arrive at 9:00 AM"
        case .disabled:
            return "Due-date alerts are off"
        case .denied:
            return "Allow notifications in iOS Settings"
        }
    }

    private var notificationIcon: String {
        switch notifications.status {
        case .enabled:
            return "bell.badge.fill"
        case .denied:
            return "bell.slash.fill"
        case .checking, .notRequested, .disabled:
            return "bell.fill"
        }
    }

    private var notificationColor: Color {
        switch notifications.status {
        case .enabled:
            return OTodoTheme.mint
        case .denied:
            return OTodoTheme.coral
        case .checking, .notRequested, .disabled:
            return OTodoTheme.accent
        }
    }

    private var notificationAccessibilityValue: String {
        switch notifications.status {
        case .checking:
            return "Checking"
        case .notRequested:
            return "Not configured"
        case .enabled:
            return "On"
        case .disabled:
            return "Off"
        case .denied:
            return "Permission required"
        }
    }

    private var notificationAccessibilityHint: String {
        switch notifications.status {
        case .enabled:
            return "Turns off due-date notifications"
        case .denied:
            return "Opens iOS Settings"
        case .checking:
            return ""
        case .notRequested, .disabled:
            return "Requests permission and schedules due-date notifications"
        }
    }

    private var inboxButton: some View {
        let isSelected = selectedFilterID == "inbox"

        return Button {
            selectFilter("inbox")
            dismissProjectSidebar()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tray")
                    .foregroundStyle(OTodoTheme.accent)
                    .frame(width: 24)
                Text("Inbox")
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .foregroundStyle(OTodoTheme.accent)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
            .background(
                isSelected ? OTodoTheme.accent.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityIdentifier("inbox-open")
    }

    private func projectFilterButton(_ project: String?) -> some View {
        let isSelected = selectedProject == project && selectedFilterID != "inbox"
        let title = project.map(projectDisplayName) ?? (isUpcoming ? "All projects" : "All Todos")
        let count = taskCount(for: project)
        let color = projectColor(project)

        return Button {
            selectProject(project)
            dismissProjectSidebar()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: project == nil ? "checklist" : "folder")
                    .font(.body)
                    .foregroundStyle(color)
                    .frame(width: 24)

                Text(title)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(project.map { "project-open-count-\($0)" } ?? "project-open-count")

                Image(systemName: "checkmark")
                    .font(.body)
                    .foregroundStyle(OTodoTheme.accent)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
            .background(
                isSelected ? OTodoTheme.accent.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) open todos")
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

    private func taskCount(for project: String?) -> Int {
        model.tasks.lazy.filter { task in
            if let project, !task.projectSlugs.contains(project) {
                return false
            }
            return state(for: task.state)?.isTerminal != true
        }.count
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
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var emptyRow: some View {
        if isFiltering {
            loadingRow
        } else if filterError == nil {
            VStack(spacing: 12) {
                Image(systemName: selectedFilterID == "all" ? "checklist" : "checkmark.circle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(OTodoTheme.accent)

                Text(selectedFilterID == "inbox" ? "Inbox is clear" : "No matching todos")
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
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private var emptyDescription: String {
        if isUpcoming {
            return "No active todos match this agenda. Choose another filter or project."
        }
        if selectedFilterID == "inbox" {
            return "New todos without a project appear here, with or without a due date. Complete them or assign a project to clear your Inbox."
        }
        if model.tasks.isEmpty {
            return "Add a todo to get started. Changes are saved locally when offline."
        }
        let projectScope = selectedProject.map {
            " in \(projectDisplayName($0))"
        } ?? ""
        switch selectedFilter.id {
        case "today":
            return "No active todos\(projectScope) are due today or overdue."
        case "active":
            return "No active todos\(projectScope). Choose All to see terminal todos."
        case "all":
            return selectedProject.map {
                "No todos in \(projectDisplayName($0)) yet."
            } ?? "Add a todo to get started."
        default:
            return "No todos\(projectScope) match this filter. Edit its query from Filters."
        }
    }

    private var filterInput: TaskFilterInput {
        TaskFilterInput(
            tasks: model.tasks,
            states: model.configuration?.states ?? [],
            filterID: selectedFilter.id,
            query: selectedFilter.query,
            selectedProject: selectedProject,
            dates: dates,
            isUpcoming: isUpcoming,
            workspaceKey: model.workspaceSelection.map(FileWorkspaceStore.selectionKey(for:)),
            isLibraryLoaded: filterLibrary.isLoaded
        )
    }

    private func updateVisibleTasks(input: TaskFilterInput) async {
        isFiltering = true
        filterError = nil
        displayedTasks = []
        agendaSections = []
        guard let query = filterLibrary.query(for: input.filterID) else {
            isFiltering = false
            filterError = "This filter could not be loaded. Open Filters to review it."
            return
        }
        let worker = Task.detached(priority: .userInitiated) {
            try Self.filteredTasks(input: input, query: query)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            displayedTasks = result.tasks
            agendaSections = result.sections
            selectedTaskIDs.formIntersection(result.tasks.map(\.id))
            isFiltering = false
        } catch is CancellationError {
            // A newer input owns the next result and loading state.
        } catch {
            guard !Task.isCancelled else { return }
            isFiltering = false
            filterError = error.localizedDescription
        }
    }

    private nonisolated static func filteredTasks(
        input: TaskFilterInput,
        query: TaskFilterQuery
    ) throws -> TaskFilterResult {
        let states = input.states
        let stateOrder = Dictionary(uniqueKeysWithValues: states.enumerated().map { ($0.element.id, $0.offset) })
        let terminalStates = Set(states.lazy.filter(\.isTerminal).map(\.id))
        var result = try input.tasks.filter { task in
            try Task.checkCancellation()
            if input.isUpcoming && terminalStates.contains(task.state) {
                return false
            }
            if let selectedProject = input.selectedProject,
               !task.projectSlugs.contains(selectedProject)
            {
                return false
            }
            return try query.matches(task, terminalStateIDs: terminalStates, dates: input.dates)
        }
        result.sort { lhs, rhs in
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

            switch (lhs.dueTime, rhs.dueTime) {
            case let (left?, right?) where left != right:
                return left < right
            case (nil, _?):
                return true
            case (_?, nil):
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
        return TaskFilterResult(
            tasks: result,
            sections: input.isUpcoming
                ? TaskAgenda.sections(tasks: result, terminalStateIDs: terminalStates, dates: input.dates)
                : []
        )
    }

    private var agendaModeButtons: some View {
        HStack {
            Button {
                isUpcoming = false
                clearSelection()
                dismissProjectSidebar()
            } label: {
                Label("Todos", systemImage: "checklist")
                    .frame(maxWidth: .infinity)
            }
            .tint(isUpcoming ? .secondary : OTodoTheme.accent)
            .accessibilityIdentifier("tasks-open")
            .accessibilityAddTraits(isUpcoming ? [] : .isSelected)

            Button {
                if !isUpcoming {
                    selectedFilterID = "active"
                }
                isUpcoming = true
                clearSelection()
                dismissProjectSidebar()
            } label: {
                Label("Upcoming", systemImage: "calendar")
                    .frame(maxWidth: .infinity)
            }
            .tint(isUpcoming ? OTodoTheme.accent : .secondary)
            .accessibilityIdentifier("upcoming-open")
            .accessibilityAddTraits(isUpcoming ? .isSelected : [])
        }
        .buttonStyle(.bordered)
        .padding(.bottom, 12)
    }

    private var selectionActions: some View {
        HStack(spacing: 8) {
            Button(selectedTaskIDs.count == displayedTasks.count ? "Deselect all" : "Select all") {
                if selectedTaskIDs.count == displayedTasks.count {
                    selectedTaskIDs.removeAll()
                } else {
                    selectedTaskIDs = Set(displayedTasks.map(\.id))
                }
            }
            .accessibilityIdentifier("upcoming-select-all")

            Text("\(selectedTaskIDs.count) selected")
                .font(.caption)
                .monospacedDigit()
                .accessibilityIdentifier("upcoming-selection-count")
            Spacer(minLength: 0)

            Button("Reschedule", systemImage: "calendar.badge.clock") {
                reschedulePresentation = ReschedulePresentation(
                    tasks: displayedTasks.filter { selectedTaskIDs.contains($0.id) }
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedTaskIDs.isEmpty)
            .accessibilityLabel("Reschedule \(selectedTaskIDs.count) selected todos")
            .accessibilityIdentifier("upcoming-reschedule")
        }
        .font(.callout)
        .disabled(model.isBusy || isFiltering)
    }

    private func clearSelection() {
        selectedTaskIDs.removeAll()
        isSelecting = false
    }

    private func toggleSelection(_ task: TodoTask) {
        if !selectedTaskIDs.insert(task.id).inserted {
            selectedTaskIDs.remove(task.id)
        }
    }

    private func agendaHeader(_ section: TaskAgendaSection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(section.group.title)
                    .font(.headline)
                Spacer()
                Text("\(section.tasks.count)")
                    .font(.caption.monospacedDigit())
            }
            Text(agendaBoundary(for: section.group))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("upcoming-section-\(section.group.rawValue)")
    }

    private func agendaBoundary(for group: TaskAgendaGroup) -> String {
        switch group {
        case .overdue: "Before \(dates.today)"
        case .today: dates.today
        case .tomorrow: dates.tomorrow
        case .nextSevenDays: "After \(dates.tomorrow), through \(dates.endOfNextSevenDays)"
        case .later: "After \(dates.endOfNextSevenDays)"
        case .noDate: "Not scheduled"
        }
    }

    @ViewBuilder
    private func taskRow(_ task: TodoTask) -> some View {
        let today = dates.today
        let workflowState = state(for: task.state)
        let canComplete = workflowState?.isTerminal != true && completionState != nil
        TaskRowView(
            task: task,
            workflowState: workflowState,
            today: today,
            isCompletionDisabled: model.isBusy
                || (isSelecting ? isFiltering : completionTarget(for: task) == nil),
            onOpen: {
                if isSelecting {
                    toggleSelection(task)
                } else {
                    editorPresentation = .edit(task)
                }
            },
            onToggleCompletion: {
                if isSelecting {
                    toggleSelection(task)
                } else {
                    toggleCompletion(task)
                }
            },
            isSelected: isSelecting ? selectedTaskIDs.contains(task.id) : nil
        )
        .contextMenu {
            if !isSelecting {
                if canComplete {
                    Button {
                        toggleCompletion(task)
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier(
                        "task-context-complete-\(task.id.rawValue)"
                    )
                }
                Button {
                    reschedulePresentation = ReschedulePresentation(tasks: [task])
                } label: {
                    Label(
                        "Reschedule",
                        systemImage: "calendar.badge.clock"
                    )
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier(
                    "task-context-reschedule-\(task.id.rawValue)"
                )

                Divider()

                Button(role: .destructive) {
                    Task { @MainActor in
                        await model.deleteTask(task)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier(
                    "task-context-delete-\(task.id.rawValue)"
                )
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !isSelecting {
                if canComplete {
                    Button {
                        toggleCompletion(task)
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .tint(OTodoTheme.mint)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier(
                        "task-complete-\(task.id.rawValue)"
                    )
                }
                Button {
                    reschedulePresentation = ReschedulePresentation(tasks: [task])
                } label: {
                    Label(
                        "Reschedule",
                        systemImage: "calendar.badge.clock"
                    )
                }
                .tint(OTodoTheme.filledViolet)
                .disabled(model.isBusy)
                .accessibilityIdentifier(
                    "task-reschedule-\(task.id.rawValue)"
                )
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isSelecting {
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
        }
        .listRowInsets(
            EdgeInsets(
                top: 0,
                leading: 20,
                bottom: 0,
                trailing: 20
            )
        )
        .listRowSeparator(.visible)
        .listRowSeparatorTint(.primary.opacity(0.08))
        .listRowBackground(Color.clear)
    }

    private var completionState: WorkflowState? {
        let states = model.configuration?.states ?? []
        return states.first(where: { $0.id == "done" && $0.isTerminal })
            ?? states.first(where: \.isTerminal)
    }


    private func completionTarget(for task: TodoTask) -> String? {
        if state(for: task.state)?.isTerminal == true {
            return model.configuration?.defaultState
        }
        return completionState?.id
    }

    private func toggleCompletion(_ task: TodoTask) {
        guard let targetState = completionTarget(for: task) else { return }
        Task { @MainActor in
            guard !model.isBusy else { return }
            var draft = TaskEditorDraft(task: task)
            draft.state = targetState
            await model.updateTask(id: task.id, draft: draft)
        }
    }

    private func state(for id: String) -> WorkflowState? {
        model.configuration?.states.first(where: { $0.id == id })
    }
}

private struct TaskFilterInput: Equatable, Sendable {
    let tasks: [TodoTask]
    let states: [WorkflowState]
    let filterID: String
    let query: String
    let selectedProject: String?
    let dates: TaskDateContext
    let isUpcoming: Bool
    let workspaceKey: String?
    let isLibraryLoaded: Bool
}

private struct TaskFilterResult: Sendable {
    let tasks: [TodoTask]
    let sections: [TaskAgendaSection]
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

private struct ReschedulePresentation: Identifiable {
    let id = UUID()
    let tasks: [TodoTask]
}
