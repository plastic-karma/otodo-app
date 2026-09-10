import Foundation
import OTodoCore
import SwiftUI

struct ProjectArchiveView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Destination: Hashable {
        case leaveInProject
        case project
        case inbox
    }

    private let project: TodoProject
    private let destinationProjects: [TodoProject]
    private let existingSlugs: Set<String>
    private let taskCount: Int
    private let openTaskCount: Int
    private let completionStateName: String?
    private let onArchive: @MainActor (ProjectArchiveDestination, Bool) async -> String?

    @State private var destination = Destination.leaveInProject
    @State private var destinationSlug = ""
    @State private var newProjectName = ""
    @State private var completesOpenTasks = false
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        project: TodoProject,
        projects: [String: TodoProject],
        existingSlugs: [String],
        tasks: [TodoTask],
        states: [WorkflowState],
        onArchive: @escaping @MainActor (ProjectArchiveDestination, Bool) async -> String?
    ) {
        self.project = project
        destinationProjects = projects.values.filter { $0.slug != project.slug && !$0.isArchived }
            .sorted { $0.slug < $1.slug }
        self.existingSlugs = Set(existingSlugs)
        let counts = tasks.reduce(into: (total: 0, open: 0)) { counts, task in
            guard task.projectSlugs.contains(project.slug) else { return }
            counts.total += 1
            if states.first(where: { $0.id == task.state })?.isTerminal != true {
                counts.open += 1
            }
        }
        taskCount = counts.total
        openTaskCount = counts.open
        completionStateName = (states.first { $0.id == "done" && $0.isTerminal }
            ?? states.first { $0.isTerminal })?.name
        self.onArchive = onArchive
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(project.name, systemImage: "folder")
                        .font(.headline)
                    Text("\(taskCount) todos · \(openTaskCount) open")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("project-archive-summary")
                } footer: {
                    Text("The project remains available under Archived projects. You can restore it later.")
                }

                Section {
                    Picker("Destination", selection: $destination) {
                        Text("Leave in project").tag(Destination.leaveInProject)
                        Text("Move to project").tag(Destination.project)
                        Text("Move to Inbox").tag(Destination.inbox)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("project-archive-destination")
                } header: {
                    Text("Todos")
                } footer: {
                    Text(destinationDescription)
                }

                if destination == .project {
                    Section {
                        Picker("Project", selection: $destinationSlug) {
                            Text("New project…").tag("")
                            ForEach(destinationProjects, id: \.slug) { target in
                                Text(target.name).tag(target.slug)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("project-archive-target")

                        if destinationSlug.isEmpty {
                            TextField("Project name", text: $newProjectName)
                                .textInputAutocapitalization(.words)
                                .submitLabel(.done)
                                .accessibilityIdentifier("project-archive-new-name")
                            LabeledContent("Slug") {
                                Text(newProjectSlug.isEmpty ? "Generated from name" : newProjectSlug)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("project-archive-new-slug")
                            }
                        }
                    } header: {
                        Text("Destination project")
                    } footer: {
                        if destinationSlug.isEmpty {
                            Text("The new project and moved todos are saved together.")
                        }
                    }
                }

                Section {
                    Toggle("Complete open todos", isOn: $completesOpenTasks)
                        .disabled(openTaskCount == 0 || completionStateName == nil)
                        .accessibilityIdentifier("project-archive-complete-open")
                } header: {
                    Text("Open todos")
                } footer: {
                    if let completionStateName {
                        Text(completesOpenTasks
                             ? "Moves \(openTaskCount) open todos to \(completionStateName). Recurring todos are ended, not rescheduled. Already finished todos stay unchanged."
                             : "Open todos keep their current state. Restoring the project later does not undo any task moves or completions.")
                    } else {
                        Text("No terminal workflow state is configured. Todos will keep their current state.")
                    }
                }

                if let message = validationMessage ?? saveError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("project-archive-error")
                    }
                }
            }
            .accessibilityIdentifier("project-archive-editor")
            .scrollContentBackground(.hidden)
            .background(OTodoTheme.formCanvas.ignoresSafeArea())
            .navigationTitle("Archive Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(OTodoTheme.formCanvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Archive") { archive() }
                        .accessibilityIdentifier("project-archive-save")
                        .disabled(validationMessage != nil || isSaving)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView("Archiving")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var newProjectSlug: String {
        ProjectEditorView.slug(from: newProjectName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var destinationDescription: String {
        switch destination {
        case .leaveInProject:
            "Keeps every project link. Open todos still appear in All Todos."
        case .project:
            "Replaces only this project's link. Other project links are preserved, including on finished todos."
        case .inbox:
            "Removes all project links, including links to other projects. Todos become unassigned."
        }
    }

    private var validationMessage: String? {
        if project.isArchived {
            return "This project is already archived."
        }
        guard destination == .project else { return nil }
        if destinationSlug.isEmpty {
            return ProjectEditorView.creationValidationMessage(
                name: newProjectName, existingSlugs: existingSlugs
            )
        }
        guard destinationProjects.contains(where: { $0.slug == destinationSlug }) else {
            return "Choose an active destination project."
        }
        return nil
    }

    private func archive() {
        guard validationMessage == nil, !isSaving else { return }
        let taskDestination: ProjectArchiveDestination
        switch destination {
        case .leaveInProject:
            taskDestination = .leaveInProject
        case .inbox:
            taskDestination = .inbox
        case .project:
            taskDestination = destinationSlug.isEmpty
                ? .newProject(
                    slug: newProjectSlug,
                    name: newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                : .project(slug: destinationSlug)
        }
        saveError = nil
        isSaving = true
        Task { @MainActor in
            let error = await onArchive(taskDestination, completesOpenTasks)
            isSaving = false
            if let error {
                saveError = error
            } else {
                dismiss()
            }
        }
    }
}
