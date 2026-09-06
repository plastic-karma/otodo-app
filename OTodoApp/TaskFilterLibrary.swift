import Foundation
import Observation
import OTodoCore

@MainActor
@Observable
final class TaskFilterLibrary {
    private(set) var filters: [SavedTaskFilter] = SavedTaskFilter.defaults
    private(set) var isLoaded = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let store: FileTaskFilterStore
    @ObservationIgnored private var selection: RepositorySelection?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var queries: [String: TaskFilterQuery] = TaskFilterLibrary.builtInQueries
    @ObservationIgnored private var operationInProgress = false
    @ObservationIgnored private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    private static var builtInQueries: [String: TaskFilterQuery] {
        ["today": .today, "active": .active, "all": .all, "inbox": .inbox]
    }

    init(store: FileTaskFilterStore) {
        self.store = store
    }

    func load(selection: RepositorySelection?) async {
        let requestedGeneration = UUID()
        generation = requestedGeneration
        if self.selection != selection {
            filters = SavedTaskFilter.defaults
            queries = Self.builtInQueries
        }
        self.selection = selection
        isLoaded = false
        errorMessage = nil

        await acquireOperation()
        defer { releaseOperation() }
        guard generation == requestedGeneration, !Task.isCancelled,
              let selection
        else { return }

        do {
            let loaded = try await store.load(selection: selection)
            let compiled = try Self.compile(loaded)
            guard generation == requestedGeneration, !Task.isCancelled else { return }
            queries = compiled
            filters = loaded
            isLoaded = true
        } catch {
            guard generation == requestedGeneration, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func query(for id: String) -> TaskFilterQuery? {
        queries[id]
    }

    /// Returns an error message on failure, or nil after the change is durably saved.
    func save(id: String?, name: String, query: String, isStarred: Bool) async -> String? {
        let savedID = id ?? UUID().uuidString
        return await persist {
            let filter = try SavedTaskFilter(
                id: savedID,
                name: name,
                query: query,
                isStarred: isStarred
            )
            guard !filter.isBuiltIn else {
                throw OTodoError.validation(field: "filter", message: "Built-in filters cannot be edited")
            }
            var updated = self.filters
            if let id {
                guard let index = updated.firstIndex(where: { $0.id == id }) else {
                    throw OTodoError.notFound(resource: "Saved filter")
                }
                updated[index] = filter
            } else {
                updated.append(filter)
            }
            return updated
        }
    }

    func toggleStar(_ filter: SavedTaskFilter) async {
        _ = await persist {
            var updated = self.filters
            guard let index = updated.firstIndex(where: { $0.id == filter.id }) else {
                throw OTodoError.notFound(resource: "Saved filter")
            }
            let current = updated[index]
            updated[index] = try SavedTaskFilter(
                id: current.id,
                name: current.name,
                query: current.query,
                isStarred: !current.isStarred
            )
            return updated
        }
    }

    func delete(_ filter: SavedTaskFilter) async {
        _ = await persist {
            guard !filter.isBuiltIn else {
                throw OTodoError.validation(field: "filter", message: "Built-in filters cannot be deleted")
            }
            guard self.filters.contains(where: { $0.id == filter.id }) else {
                throw OTodoError.notFound(resource: "Saved filter")
            }
            return self.filters.filter { $0.id != filter.id }
        }
    }

    private func persist(_ change: () throws -> [SavedTaskFilter]) async -> String? {
        let requestedGeneration = generation
        await acquireOperation()
        defer { releaseOperation() }
        guard generation == requestedGeneration, !Task.isCancelled else {
            return "The workspace changed or the filter operation was cancelled."
        }
        guard isLoaded, let selection else {
            errorMessage = errorMessage ?? "Load this workspace's saved filters before making changes."
            return errorMessage
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let updated = try change()
            let compiled = try Self.compile(updated, reusing: queries, previous: filters)
            try await store.save(updated, selection: selection)
            guard generation == requestedGeneration else {
                return "The workspace changed while saving the filter."
            }
            queries = compiled
            filters = updated
            return nil
        } catch {
            guard generation == requestedGeneration else {
                return error.localizedDescription
            }
            errorMessage = error.localizedDescription
            return errorMessage
        }
    }

    private static func compile(
        _ filters: [SavedTaskFilter],
        reusing cached: [String: TaskFilterQuery] = [:],
        previous: [SavedTaskFilter] = []
    ) throws -> [String: TaskFilterQuery] {
        var result = builtInQueries
        let oldSources = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0.query) })
        for filter in filters where !filter.isBuiltIn {
            if oldSources[filter.id] == filter.query, let query = cached[filter.id] {
                result[filter.id] = query
            } else {
                result[filter.id] = try TaskFilterQuery(filter.query)
            }
        }
        return result
    }

    // A load also takes this lock, so switching away and back cannot read ahead of a pending save.
    private func acquireOperation() async {
        if operationInProgress {
            await withCheckedContinuation { operationWaiters.append($0) }
        } else {
            operationInProgress = true
        }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty {
            operationInProgress = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }
}
