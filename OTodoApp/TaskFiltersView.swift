import Foundation
import OTodoCore
import SwiftUI

struct TaskFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var library: TaskFilterLibrary
    let projectChoices: [String]
    let tagChoices: [String]
    let onSelect: (SavedTaskFilter) -> Void
    @State private var editor: FilterEditorPresentation?

    var body: some View {
        NavigationStack {
            List {
                if let message = library.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section("Predefined") {
                    ForEach(library.filters) { filter in
                        if filter.isBuiltIn { filterRow(filter) }
                    }
                }

                Section {
                    ForEach(library.filters) { filter in
                        if !filter.isBuiltIn { filterRow(filter) }
                    }
                    if !library.filters.contains(where: { !$0.isBuiltIn }) {
                        Text("Save a query to make it a reusable view of your todos.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Saved")
                } footer: {
                    Text("Star filters to show them on Home. Touch and hold a saved filter to edit or delete it. Filters are saved on this device, separately for each repository workspace.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(OTodoCanvas())
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("filter-library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("filters-done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Filter", systemImage: "plus") { editor = .create }
                        .disabled(!library.isLoaded || library.isSaving)
                        .accessibilityIdentifier("filter-add")
                }
            }
            .sheet(item: $editor) { presentation in
                TaskFilterEditorView(
                    library: library, filter: presentation.filter,
                    projectChoices: projectChoices, tagChoices: tagChoices
                )
            }
        }
    }

    private func filterRow(_ filter: SavedTaskFilter) -> some View {
        HStack(spacing: 12) {
            Button {
                onSelect(filter)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(filter.name)
                        .foregroundStyle(.primary)
                    Text(filter.query)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(filter.name)
            .accessibilityIdentifier("filter-open-\(filter.id)")
            .contextMenu {
                if !filter.isBuiltIn {
                    Button("Edit Filter", systemImage: "pencil") { editor = .edit(filter) }
                        .accessibilityIdentifier("filter-edit-\(filter.id)")
                    Button("Delete Filter", systemImage: "trash", role: .destructive) {
                        Task { await library.delete(filter) }
                    }
                    .accessibilityIdentifier("filter-delete-\(filter.id)")
                }
            }

            Button {
                Task { await library.toggleStar(filter) }
            } label: {
                Image(systemName: filter.isStarred ? "star.fill" : "star")
                    .foregroundStyle(filter.isStarred ? OTodoTheme.accent : .secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Show \(filter.name) on Home")
            .accessibilityValue(filter.isStarred ? "On" : "Off")
            .accessibilityIdentifier("filter-star-\(filter.id)")
        }
        .disabled(!library.isLoaded || library.isSaving)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !filter.isBuiltIn {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    Task { await library.delete(filter) }
                }
                Button("Edit", systemImage: "pencil") { editor = .edit(filter) }
                    .tint(OTodoTheme.filledAccent)
            }
        }
    }
}

private struct TaskFilterEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var library: TaskFilterLibrary
    private let filter: SavedTaskFilter?
    private let projectChoices: [String]
    private let tagChoices: [String]
    @State private var name: String
    @State private var query: String
    @State private var querySelection: NSRange
    @State private var isQueryFocused = false
    @State private var isQueryComposing = false
    @ScaledMetric(relativeTo: .body) private var queryHeight = 120
    @State private var isStarred: Bool
    @State private var queryError: String?
    @State private var saveError: String?

    init(library: TaskFilterLibrary, filter: SavedTaskFilter?, projectChoices: [String], tagChoices: [String]) {
        self.library = library
        self.filter = filter
        self.projectChoices = projectChoices
        self.tagChoices = tagChoices
        _name = State(initialValue: filter?.name ?? "")
        _query = State(initialValue: filter?.query ?? "")
        _querySelection = State(initialValue: NSRange(location: (filter?.query ?? "").utf16.count, length: 0))
        _isStarred = State(initialValue: filter?.isStarred ?? false)
        _queryError = State(initialValue: filter == nil ? "Enter a filter query." : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Filter name", text: $name)
                        .accessibilityIdentifier("filter-editor-name")
                    TaskFilterQueryField(
                        text: $query, selection: $querySelection,
                        isFocused: $isQueryFocused, isComposing: $isQueryComposing
                    )
                        .frame(height: queryHeight)
                        .onChange(of: query) { _, value in
                            do {
                                _ = try TaskFilterQuery(value)
                                queryError = nil
                            } catch {
                                queryError = error.localizedDescription
                            }
                            saveError = nil
                        }
                    let suggestions = querySuggestions
                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Project and tag suggestions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(suggestions, id: \.value) { suggestion in
                                        Button {
                                            guard let result = suggestion.applying(to: query) else { return }
                                            query = result.query
                                            querySelection = result.selection
                                            isQueryFocused = true
                                        } label: {
                                            Label(
                                                suggestion.value,
                                                systemImage: suggestion.field == "project" ? "folder" : "number"
                                            )
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 10)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("\(suggestion.field == "project" ? "Project" : "Tag"): \(suggestion.value)")
                                        .accessibilityIdentifier("filter-completion-\(suggestion.field)-\(suggestion.value)")
                                    }
                                }
                            }
                            .frame(maxHeight: queryHeight)
                        }
                        .accessibilityIdentifier("filter-editor-suggestions")
                    }
                    Button {
                        isStarred.toggle()
                    } label: {
                        Label(
                            isStarred ? "Starred on Home" : "Star on Home",
                            systemImage: isStarred ? "star.fill" : "star"
                        )
                    }
                    .accessibilityIdentifier("filter-editor-star")
                    .accessibilityValue(isStarred ? "On" : "Off")
                }

                if let message = saveError ?? (query.isEmpty ? nil : queryError) {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("filter-editor-error")
                    }
                }

                Section("Query guide") {
                    Text("Combine terms with AND, OR, NOT (or &, |, !). Parentheses group terms; NOT binds first, then AND, then OR.")
                    Text("all · active · today · inbox\nToday includes active overdue todos. Inbox includes active todos without a project, regardless of due date.")
                    Text("overdue · tomorrow · next-seven-days · undated\nDate predicates select active todos. Next-seven-days covers tomorrow through today + 7 local calendar days.")
                    Text("due:2026-09-05\ndue:2026-09-01..2026-09-07\n(overdue OR next-seven-days) AND project:work")
                        .font(.system(.footnote, design: .monospaced))
                    Text("Use valid YYYY-MM-DD dates. Date ranges include both endpoints. Relative dates follow the device's local calendar and update when the day changes.")
                    Text("project:work AND tag:focus\nactive AND NOT tag:waiting\n(project:home OR project:work) AND today")
                        .font(.system(.footnote, design: .monospaced))
                    Text("name:/report/i\ndescription:/invoice|receipt/i")
                        .font(.system(.footnote, design: .monospaced))
                    Text("Tags and project slugs match exactly. Double-quote values containing operators. Name and description use /regular expressions/; optional i ignores case, m enables line anchors, and s lets dots match newlines. Escape a slash as \\/.")
                    Text("Type project: or tag: to see local suggestions. Tap a suggestion to replace the value at the cursor without changing the rest of your query.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .scrollContentBackground(.hidden)
            .background(OTodoCanvas())
            .navigationTitle(filter == nil ? "New Filter" : "Edit Filter")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("filter-editor")
            .interactiveDismissDisabled(library.isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .disabled(library.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            saveError = await library.save(
                                id: filter?.id,
                                name: name,
                                query: query,
                                isStarred: isStarred
                            )
                            if saveError == nil { dismiss() }
                        }
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || queryError != nil || !library.isLoaded || library.isSaving
                    )
                    .accessibilityIdentifier("filter-editor-save")
                }
            }
        }
    }

    private var querySuggestions: [TaskFilterCompletion.Suggestion] {
        guard isQueryFocused, !isQueryComposing else { return [] }
        return TaskFilterCompletion.suggestions(
            in: query, selection: querySelection,
            projectChoices: projectChoices, tagChoices: tagChoices
        )
    }
}

private enum FilterEditorPresentation: Identifiable {
    case create
    case edit(SavedTaskFilter)

    var id: String { filter?.id ?? "new-filter" }

    var filter: SavedTaskFilter? {
        if case let .edit(filter) = self { return filter }
        return nil
    }
}
