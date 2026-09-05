import Foundation

/// Local-only saved filters, isolated by the complete repository selection.
public actor FileTaskFilterStore {
    private static let formatVersion = 1
    private static let persistenceLock = NSLock()

    private struct Envelope: Codable {
        let version: Int
        let selection: RepositorySelection
        let filters: [SavedTaskFilter]
    }

    private let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func load(selection: RepositorySelection) async throws -> [SavedTaskFilter] {
        try requireFileRoot()
        return try Self.persistenceLock.withLock {
            try loadPersistedFilters(selection: selection) ?? SavedTaskFilter.defaults
        }
    }

    public func save(_ filters: [SavedTaskFilter], selection: RepositorySelection) async throws {
        try requireFileRoot()
        try Self.validate(filters)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(
            version: Self.formatVersion,
            selection: selection,
            filters: filters
        ))

        try Self.persistenceLock.withLock {
            // Never replace unreadable, malformed, or unsupported existing data.
            let destinationExists = try loadPersistedFilters(selection: selection) != nil
            let fileManager = FileManager.default
            let destinationURL = filtersURL(for: selection)
            let temporaryURL = rootURL.appendingPathComponent(
                ".\(FileWorkspaceStore.selectionKey(for: selection)).\(UUID().uuidString).tmp",
                isDirectory: false
            )
            defer { try? fileManager.removeItem(at: temporaryURL) }

            do {
                try fileManager.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try FileWorkspaceStore.setPermissions(0o700, at: rootURL)
                try data.write(to: temporaryURL, options: .withoutOverwriting)
                try FileWorkspaceStore.setPermissions(0o600, at: temporaryURL)
                if destinationExists {
                    try FileWorkspaceStore.atomicallyReplaceItem(
                        at: destinationURL,
                        withItemAt: temporaryURL,
                        fileManager: fileManager
                    )
                } else {
                    try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                }
                // The replacement inherits the temporary file's private permissions.
            } catch {
                throw OTodoError.corruptLocalState(
                    message: "Could not atomically save task filters: \(error.localizedDescription)"
                )
            }
        }
    }

    private func requireFileRoot() throws {
        guard rootURL.isFileURL else {
            throw OTodoError.corruptLocalState(message: "Task filter root must be a file URL")
        }
    }

    private func filtersURL(for selection: RepositorySelection) -> URL {
        rootURL.appendingPathComponent(
            "\(FileWorkspaceStore.selectionKey(for: selection)).json",
            isDirectory: false
        )
    }

    private func loadPersistedFilters(selection: RepositorySelection) throws -> [SavedTaskFilter]? {
        let data: Data
        do {
            data = try Data(contentsOf: filtersURL(for: selection))
        } catch {
            let readError = error as NSError
            if readError.domain == NSCocoaErrorDomain, readError.code == NSFileReadNoSuchFileError {
                return nil
            }
            throw OTodoError.corruptLocalState(
                message: "Could not read task filters: \(error.localizedDescription)"
            )
        }

        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == Self.formatVersion else {
                throw OTodoError.corruptLocalState(
                    message: "Unsupported task filter persistence version \(envelope.version)"
                )
            }
            guard envelope.selection == selection else {
                throw OTodoError.corruptLocalState(
                    message: "Task filter selection does not match its persistence key"
                )
            }
            try Self.validate(envelope.filters)
            return envelope.filters
        } catch let error as OTodoError {
            if case .corruptLocalState = error { throw error }
            throw OTodoError.corruptLocalState(
                message: "Task filters contain invalid persisted data: \(error.localizedDescription)"
            )
        } catch {
            throw OTodoError.corruptLocalState(
                message: "Could not decode task filters: \(error.localizedDescription)"
            )
        }
    }

    private nonisolated static func validate(_ filters: [SavedTaskFilter]) throws {
        let ids = Set(filters.map(\.id))
        guard ids.count == filters.count else {
            throw OTodoError.validation(field: "filters", message: "Filter IDs must be unique")
        }
        guard SavedTaskFilter.defaults.allSatisfy({ ids.contains($0.id) }) else {
            throw OTodoError.validation(field: "filters", message: "Built-in filters cannot be removed")
        }
    }
}
