import Foundation
import OTodoCore
import SwiftUI

struct TaskFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var library: TaskFilterLibrary
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
                TaskFilterEditorView(library: library, filter: presentation.filter)
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
    @State private var name: String
    @State private var query: String
    @State private var isStarred: Bool
    @State private var queryError: String?
    @State private var saveError: String?

    init(library: TaskFilterLibrary, filter: SavedTaskFilter?) {
        self.library = library
        self.filter = filter
        _name = State(initialValue: filter?.name ?? "")
        _query = State(initialValue: filter?.query ?? "")
        _isStarred = State(initialValue: filter?.isStarred ?? false)
        _queryError = State(initialValue: filter == nil ? "Enter a filter query." : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Filter name", text: $name)
                        .accessibilityIdentifier("filter-editor-name")
                    TextField("active AND project:work", text: $query, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(3...8)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Filter query")
                        .accessibilityIdentifier("filter-editor-query")
                        .onChange(of: query) { _, value in
                            do {
                                _ = try TaskFilterQuery(value)
                                queryError = nil
                            } catch {
                                queryError = error.localizedDescription
                            }
                            saveError = nil
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
                    Text("all · active · today\nToday includes active overdue todos.")
                    Text("project:work AND tag:focus\nactive AND NOT tag:waiting\n(project:home OR project:work) AND today")
                        .font(.system(.footnote, design: .monospaced))
                    Text("name:/report/i\ndescription:/invoice|receipt/i")
                        .font(.system(.footnote, design: .monospaced))
                    Text("Tags and project slugs match exactly. Double-quote values containing operators. Name and description use /regular expressions/; optional i ignores case, m enables line anchors, and s lets dots match newlines. Escape a slash as \\/.")
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
