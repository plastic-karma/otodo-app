import Foundation

public struct TaskUpdate: Sendable, Equatable {
    public var name: String
    public var state: String
    public var projectSlugs: [String]
    public var tags: [String]
    public var dueDate: CivilDate?
    public var dueTime: CivilTime?
    public var body: String

    public init(
        name: String,
        state: String,
        projectSlugs: [String],
        tags: [String],
        dueDate: CivilDate?,
        dueTime: CivilTime? = nil,
        body: String
    ) {
        self.name = name
        self.state = state
        self.projectSlugs = projectSlugs
        self.tags = tags
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.body = body
    }

    public init(task: TodoTask) {
        self.init(
            name: task.name,
            state: task.state,
            projectSlugs: task.projectSlugs,
            tags: task.tags,
            dueDate: task.dueDate,
            dueTime: task.dueTime,
            body: task.body
        )
    }
}

public enum WorkspaceConflictResolution: Sendable, Equatable {
    case keepLocal
    case useRemote
}

/// Offline-first task operations. Every mutation is validated, reflected in the
/// durable outbox, and saved before its result is returned.
public actor TaskWorkspaceService {
    private let persistence: any WorkspacePersisting
    private let taskCodec: any TaskRecordCoding
    private let ulidGenerator: any ULIDGenerating
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID

    public init(
        persistence: any WorkspacePersisting,
        taskCodec: any TaskRecordCoding,
        ulidGenerator: any ULIDGenerating = ULIDGenerator(),
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.persistence = persistence
        self.taskCodec = taskCodec
        self.ulidGenerator = ulidGenerator
        self.now = now
        self.makeUUID = makeUUID
    }

    public func load(selection: RepositorySelection) async throws -> WorkspaceState? {
        guard let workspace = try await persistence.load(selection: selection) else {
            return nil
        }
        try Self.validateSelection(workspace, expected: selection)
        return workspace
    }

    public func loadWorkspace(selection: RepositorySelection) async throws -> WorkspaceState {
        try await requireWorkspace(selection: selection)
    }

    public func loadTask(
        selection: RepositorySelection,
        id: TaskID
    ) async throws -> TodoTask {
        let workspace = try await requireWorkspace(selection: selection)
        guard let document = workspace.tasks.first(where: { $0.task.id == id }) else {
            throw OTodoError.notFound(resource: "task \(id.rawValue)")
        }
        return document.task
    }

    /// Returns nonterminal tasks by default, ordered by due date and time
    /// (date-only before timed, undated last), configured state order, exact UTF-8 name order, then ULID.
    public func listTasks(
        selection: RepositorySelection,
        includeTerminal: Bool = false
    ) async throws -> [TodoTask] {
        let workspace = try await requireWorkspace(selection: selection)
        let stateMetadata = Dictionary(
            uniqueKeysWithValues: workspace.configuration.states.enumerated().map {
                ($0.element.id, (order: $0.offset, isTerminal: $0.element.isTerminal))
            }
        )

        var tasks = [TodoTask]()
        tasks.reserveCapacity(workspace.tasks.count)
        for document in workspace.tasks {
            guard let configuredState = stateMetadata[document.task.state] else {
                throw OTodoError.corruptLocalState(
                    message: "Task \(document.task.id.rawValue) uses unconfigured state \(document.task.state)"
                )
            }
            if includeTerminal || !configuredState.isTerminal {
                tasks.append(document.task)
            }
        }

        tasks.sort { lhs, rhs in
            if lhs.dueDate != rhs.dueDate {
                switch (lhs.dueDate, rhs.dueDate) {
                case let (left?, right?): return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): break
                }
            }
            if lhs.dueTime != rhs.dueTime {
                switch (lhs.dueTime, rhs.dueTime) {
                case let (left?, right?): return left < right
                case (nil, _?): return true
                case (_?, nil): return false
                case (nil, nil): break
                }
            }
            let leftState = stateMetadata[lhs.state]?.order ?? Int.max
            let rightState = stateMetadata[rhs.state]?.order ?? Int.max
            if leftState != rightState { return leftState < rightState }

            let leftName = lhs.name.utf8
            let rightName = rhs.name.utf8
            if !leftName.elementsEqual(rightName) {
                return leftName.lexicographicallyPrecedes(rightName)
            }
            return lhs.id < rhs.id
        }
        return tasks
    }

    /// Creates a direct Markdown project record and adds it to the durable outbox.
    @discardableResult
    public func addProject(
        selection: RepositorySelection,
        slug: String,
        title: String
    ) async throws -> String {
        let workspace = try await requireWorkspace(selection: selection)
        _ = try workspace.configuration.projectLink(slug: slug)

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              !trimmedTitle.contains("\n"),
              !trimmedTitle.contains("\r")
        else {
            throw OTodoError.validation(
                field: "project.title",
                message: "Project title must be nonempty and single-line"
            )
        }
        guard !workspace.knownProjectSlugs.contains(slug) else {
            throw OTodoError.validation(
                field: "projects",
                message: "Project \(slug) already exists"
            )
        }

        let relativePath = "\(workspace.configuration.projectsDirectory)/\(slug).md"
        let repositoryPath = Self.repositoryPath(
            selection: workspace.selection,
            storeRelativePath: relativePath
        )
        guard !workspace.conflicts.contains(where: { $0.path == repositoryPath }) else {
            throw OTodoError.conflict(
                message: "Resolve the conflict at \(repositoryPath) before creating this project"
            )
        }

        let content = "# \(trimmedTitle)\n"
        let pendingChanges = try upsertingPendingChange(
            path: repositoryPath,
            content: content,
            baseBlobSHA: nil,
            in: workspace.pendingChanges,
            at: now()
        )
        let knownProjectSlugs = (workspace.knownProjectSlugs + [slug]).sorted()
        let updatedWorkspace = try Self.replacing(
            workspace,
            knownProjectSlugs: knownProjectSlugs,
            tasks: workspace.tasks,
            pendingChanges: pendingChanges,
            conflicts: workspace.conflicts
        )
        try await persistence.save(updatedWorkspace, expectedRevision: workspace.revision)
        return slug
    }

    public func addTask(
        selection: RepositorySelection,
        name: String,
        state: String? = nil,
        projectSlugs: [String] = [],
        tags: [String] = [],
        dueDate: CivilDate? = nil,
        dueTime: CivilTime? = nil,
        recurrence: String? = nil,
        recurrenceFrom: RecurrenceFrom? = nil,
        lastCompletedDate: CivilDate? = nil,
        body: String = ""
    ) async throws -> TodoTask {
        let workspace = try await requireWorkspace(selection: selection)
        let selectedState = state ?? workspace.configuration.defaultState
        try Self.validate(state: selectedState, projects: projectSlugs, in: workspace)

        let timestamp = now()
        let id = try generateUniqueID(in: workspace, at: timestamp)
        let relativePath = "\(workspace.configuration.tasksDirectory)/\(id.rawValue).md"
        let task = try TodoTask(
            id: id,
            relativePath: relativePath,
            name: name,
            state: selectedState,
            projectSlugs: projectSlugs,
            tags: tags,
            dueDate: dueDate,
            dueTime: dueTime,
            recurrence: recurrence,
            recurrenceFrom: recurrenceFrom,
            lastCompletedDate: lastCompletedDate,
            body: body,
            extraProperties: [
                YAMLProperty(
                    name: "base",
                    value: .string(workspace.configuration.todosBaseLink)
                ),
            ]
        )
        let document = try canonicalDocument(
            for: task,
            configuration: workspace.configuration,
            blobSHA: nil
        )
        let repositoryPath = Self.repositoryPath(
            selection: workspace.selection,
            storeRelativePath: relativePath
        )
        guard !workspace.conflicts.contains(where: { $0.path == repositoryPath }) else {
            throw OTodoError.conflict(message: "Resolve the conflict at \(repositoryPath) before editing")
        }

        var tasks = workspace.tasks
        tasks.append(document)
        let pendingChanges = try upsertingPendingChange(
            path: repositoryPath,
            content: document.content,
            baseBlobSHA: nil,
            in: workspace.pendingChanges,
            at: timestamp
        )
        let updatedWorkspace = try Self.replacing(
            workspace,
            tasks: tasks,
            pendingChanges: pendingChanges,
            conflicts: workspace.conflicts
        )
        try await persistence.save(updatedWorkspace, expectedRevision: workspace.revision)
        return document.task
    }

    public func editTask(
        selection: RepositorySelection,
        id: TaskID,
        expectedTask: TodoTask,
        update: TaskUpdate
    ) async throws -> TodoTask {
        let workspace = try await requireWorkspace(selection: selection)
        guard let taskIndex = workspace.tasks.firstIndex(where: { $0.task.id == id }) else {
            throw OTodoError.notFound(resource: "task \(id.rawValue)")
        }
        guard workspace.tasks[taskIndex].task == expectedTask else {
            throw OTodoError.conflict(
                message: "Task \(id.rawValue) changed since editing began"
            )
        }
        try Self.validate(state: update.state, projects: update.projectSlugs, in: workspace)

        let original = workspace.tasks[taskIndex]
        let repositoryPath = Self.repositoryPath(
            selection: workspace.selection,
            storeRelativePath: original.task.relativePath
        )
        guard !workspace.conflicts.contains(where: { $0.path == repositoryPath }) else {
            throw OTodoError.conflict(message: "Resolve the conflict at \(repositoryPath) before editing")
        }

        let editedTask = try TodoTask(
            id: original.task.id,
            relativePath: original.task.relativePath,
            name: update.name,
            state: update.state,
            projectSlugs: update.projectSlugs,
            tags: update.tags,
            dueDate: update.dueDate,
            dueTime: update.dueTime,
            recurrence: original.task.recurrence,
            recurrenceFrom: original.task.recurrenceFrom,
            lastCompletedDate: original.task.lastCompletedDate,
            body: update.body,
            extraProperties: original.task.extraProperties
        )
        let document = try canonicalDocument(
            for: editedTask,
            configuration: workspace.configuration,
            blobSHA: original.blobSHA
        )

        var tasks = workspace.tasks
        tasks[taskIndex] = document
        let pendingChanges = try upsertingPendingChange(
            path: repositoryPath,
            content: document.content,
            baseBlobSHA: original.blobSHA,
            in: workspace.pendingChanges,
            at: now()
        )
        let updatedWorkspace = try Self.replacing(
            workspace,
            tasks: tasks,
            pendingChanges: pendingChanges,
            conflicts: workspace.conflicts
        )
        try await persistence.save(updatedWorkspace, expectedRevision: workspace.revision)
        return document.task
    }

    public func editTask(
        selection: RepositorySelection,
        id: TaskID,
        expectedTask: TodoTask,
        name: String,
        state: String,
        projectSlugs: [String],
        tags: [String],
        dueDate: CivilDate?,
        dueTime: CivilTime? = nil,
        body: String
    ) async throws -> TodoTask {
        try await editTask(
            selection: selection,
            id: id,
            expectedTask: expectedTask,
            update: TaskUpdate(
                name: name,
                state: state,
                projectSlugs: projectSlugs,
                tags: tags,
                dueDate: dueDate,
                dueTime: dueTime,
                body: body
            )
        )
    }

    public func deleteTask(
        selection: RepositorySelection,
        id: TaskID,
        expectedTask: TodoTask
    ) async throws {
        let workspace = try await requireWorkspace(selection: selection)
        guard let taskIndex = workspace.tasks.firstIndex(where: { $0.task.id == id }) else {
            throw OTodoError.notFound(resource: "task \(id.rawValue)")
        }
        guard workspace.tasks[taskIndex].task == expectedTask else {
            throw OTodoError.conflict(
                message: "Task \(id.rawValue) changed since deletion began"
            )
        }

        let original = workspace.tasks[taskIndex]
        let repositoryPath = Self.repositoryPath(
            selection: workspace.selection,
            storeRelativePath: original.task.relativePath
        )
        guard !workspace.conflicts.contains(where: { $0.path == repositoryPath }) else {
            throw OTodoError.conflict(message: "Resolve the conflict at \(repositoryPath) before deleting")
        }

        var tasks = workspace.tasks
        tasks.remove(at: taskIndex)

        let existingPending = workspace.pendingChanges.first(where: { $0.path == repositoryPath })
        let remoteBaseBlobSHA = existingPending?.baseBlobSHA ?? original.blobSHA
        let pendingChanges: [PendingChange]
        if remoteBaseBlobSHA == nil {
            pendingChanges = workspace.pendingChanges.filter { $0.path != repositoryPath }
        } else {
            pendingChanges = try upsertingPendingChange(
                path: repositoryPath,
                content: nil,
                baseBlobSHA: remoteBaseBlobSHA,
                in: workspace.pendingChanges,
                at: now()
            )
        }
        let updatedWorkspace = try Self.replacing(
            workspace,
            tasks: tasks,
            pendingChanges: pendingChanges,
            conflicts: workspace.conflicts
        )
        try await persistence.save(updatedWorkspace, expectedRevision: workspace.revision)
    }

    public func resolveConflict(
        selection: RepositorySelection,
        path: String,
        resolution: WorkspaceConflictResolution
    ) async throws -> WorkspaceState {
        let workspace = try await requireWorkspace(selection: selection)
        guard let conflictIndex = workspace.conflicts.firstIndex(where: { $0.path == path }) else {
            throw OTodoError.notFound(resource: "conflict at \(path)")
        }
        let conflict = workspace.conflicts[conflictIndex]
        let relativePath = try Self.storeRelativePath(for: path, selection: workspace.selection)

        var tasks = workspace.tasks
        var pendingChanges = workspace.pendingChanges
        switch resolution {
        case .keepLocal:
            if let localContent = conflict.localContent {
                let id = try Self.taskIDFromBasename(for: relativePath)
                let destinationRelativePath =
                    "\(workspace.configuration.tasksDirectory)/\(id.rawValue).md"
                let destinationPath = Self.repositoryPath(
                    selection: workspace.selection,
                    storeRelativePath: destinationRelativePath
                )
                if destinationPath != path {
                    guard !workspace.pendingChanges.contains(where: { $0.path == destinationPath }),
                          !workspace.conflicts.contains(where: { $0.path == destinationPath })
                    else {
                        throw OTodoError.conflict(
                            message: "Cannot move local task to occupied path \(destinationPath)"
                        )
                    }
                }

                let destinationBlobSHA = tasks.first(where: {
                    $0.task.relativePath == destinationRelativePath
                })?.blobSHA
                let parsed = try taskCodec.parseTask(
                    id: id,
                    relativePath: destinationRelativePath,
                    text: localContent,
                    configuration: workspace.configuration
                )
                try Self.validate(state: parsed.state, projects: parsed.projectSlugs, in: workspace)
                let document = try canonicalDocument(
                    for: parsed,
                    configuration: workspace.configuration,
                    blobSHA: destinationPath == path ? conflict.remoteBlobSHA : destinationBlobSHA
                )
                try Self.replaceOrRemap(document, in: &tasks)
                pendingChanges = try replacingConflictPendingChange(
                    conflict: conflict,
                    destinationPath: destinationPath,
                    baseBlobSHA: document.blobSHA,
                    content: document.content,
                    pendingChanges: pendingChanges
                )
            } else {
                tasks.removeAll(where: { $0.task.relativePath == relativePath })
                pendingChanges = try replacingConflictPendingChange(
                    conflict: conflict,
                    destinationPath: path,
                    baseBlobSHA: conflict.remoteBlobSHA,
                    content: nil,
                    pendingChanges: pendingChanges
                )
            }

        case .useRemote:
            pendingChanges.removeAll(where: { $0.path == path })
            if let id = try Self.taskIDForCurrentLayout(
                relativePath,
                configuration: workspace.configuration
            ) {
                if let remoteContent = conflict.remoteContent {
                    let task = try taskCodec.parseTask(
                        id: id,
                        relativePath: relativePath,
                        text: remoteContent,
                        configuration: workspace.configuration
                    )
                    try Self.validate(state: task.state, projects: task.projectSlugs, in: workspace)
                    try Self.replaceOrInsert(
                        TaskDocument(
                            task: task,
                            content: remoteContent,
                            blobSHA: conflict.remoteBlobSHA
                        ),
                        in: &tasks
                    )
                } else {
                    tasks.removeAll(where: { $0.task.relativePath == relativePath })
                }
            } else {
                // A configuration pull can move the task directory while preserving a conflict
                // for an old pending path. That old path is no longer a task in the current
                // layout, so accepting remote only discards its local overlay.
                tasks.removeAll(where: { $0.task.relativePath == relativePath })
            }
        }

        var conflicts = workspace.conflicts
        conflicts.remove(at: conflictIndex)
        let updatedWorkspace = try Self.replacing(
            workspace,
            tasks: tasks,
            pendingChanges: pendingChanges,
            conflicts: conflicts
        )
        try await persistence.save(updatedWorkspace, expectedRevision: workspace.revision)
        return updatedWorkspace
    }

    public func keepLocalConflict(
        selection: RepositorySelection,
        path: String
    ) async throws -> WorkspaceState {
        try await resolveConflict(selection: selection, path: path, resolution: .keepLocal)
    }

    public func useRemoteConflict(
        selection: RepositorySelection,
        path: String
    ) async throws -> WorkspaceState {
        try await resolveConflict(selection: selection, path: path, resolution: .useRemote)
    }

    private func requireWorkspace(selection: RepositorySelection) async throws -> WorkspaceState {
        guard let workspace = try await persistence.load(selection: selection) else {
            throw OTodoError.notFound(resource: "workspace \(selection.owner)/\(selection.name)")
        }
        try Self.validateSelection(workspace, expected: selection)
        return workspace
    }

    private func generateUniqueID(in workspace: WorkspaceState, at date: Date) throws -> TaskID {
        var existingIDs = Set(workspace.tasks.map(\.task.id))
        var occupiedPaths = Set(workspace.pendingChanges.map(\.path))
        occupiedPaths.formUnion(workspace.conflicts.map(\.path))
        for path in occupiedPaths {
            if let relativePath = try? Self.storeRelativePath(
                for: path,
                selection: workspace.selection
            ), let occupiedID = try? Self.taskID(
                for: relativePath,
                configuration: workspace.configuration
            ) {
                existingIDs.insert(occupiedID)
            }
        }
        for attempt in 0 ..< 128 {
            let candidate = try ulidGenerator.generate(
                at: date.addingTimeInterval(Double(attempt) / 1_000)
            )
            let relativePath = "\(workspace.configuration.tasksDirectory)/\(candidate.rawValue).md"
            let path = Self.repositoryPath(
                selection: workspace.selection,
                storeRelativePath: relativePath
            )
            if !existingIDs.contains(candidate), !occupiedPaths.contains(path) {
                return candidate
            }
        }
        throw OTodoError.conflict(message: "Could not generate a unique task ULID")
    }

    private func canonicalDocument(
        for task: TodoTask,
        configuration: StoreConfiguration,
        blobSHA: String?
    ) throws -> TaskDocument {
        let content = try taskCodec.serializeTask(task, configuration: configuration)
        let canonicalTask = try taskCodec.parseTask(
            id: task.id,
            relativePath: task.relativePath,
            text: content,
            configuration: configuration
        )
        guard canonicalTask.id == task.id,
              canonicalTask.relativePath == task.relativePath
        else {
            throw OTodoError.validation(
                field: "task",
                message: "Task codec changed task identity while canonicalizing"
            )
        }
        return TaskDocument(task: canonicalTask, content: content, blobSHA: blobSHA)
    }

    private func upsertingPendingChange(
        path: String,
        content: String?,
        baseBlobSHA: String?,
        in pendingChanges: [PendingChange],
        at date: Date
    ) throws -> [PendingChange] {
        var result = pendingChanges
        if let index = result.firstIndex(where: { $0.path == path }) {
            let original = result[index]
            result[index] = try PendingChange(
                id: original.id,
                path: path,
                baseBlobSHA: original.baseBlobSHA,
                content: content,
                createdAt: original.createdAt
            )
        } else {
            result.append(try PendingChange(
                id: makeUUID(),
                path: path,
                baseBlobSHA: baseBlobSHA,
                content: content,
                createdAt: date
            ))
        }
        return result
    }

    private func replacingConflictPendingChange(
        conflict: SyncConflict,
        destinationPath: String,
        baseBlobSHA: String?,
        content: String?,
        pendingChanges: [PendingChange]
    ) throws -> [PendingChange] {
        let source = pendingChanges.first(where: { $0.path == conflict.path })
        var result = pendingChanges.filter { $0.path != conflict.path }
        guard !result.contains(where: { $0.path == destinationPath }) else {
            throw OTodoError.conflict(
                message: "Cannot move local task to occupied path \(destinationPath)"
            )
        }
        result.append(try PendingChange(
            id: source?.id ?? makeUUID(),
            path: destinationPath,
            baseBlobSHA: baseBlobSHA,
            content: content,
            createdAt: source?.createdAt ?? now()
        ))
        return result
    }

    private static func validateSelection(
        _ workspace: WorkspaceState,
        expected selection: RepositorySelection
    ) throws {
        guard workspace.selection == selection else {
            throw OTodoError.corruptLocalState(message: "Loaded workspace has the wrong repository selection")
        }
    }

    private static func validate(
        state: String,
        projects: [String],
        in workspace: WorkspaceState
    ) throws {
        guard workspace.configuration.states.contains(where: { $0.id == state }) else {
            throw OTodoError.validation(field: "state", message: "State is not configured")
        }
        let knownProjects = Set(workspace.knownProjectSlugs)
        guard projects.allSatisfy(knownProjects.contains) else {
            let unknown = projects.filter { !knownProjects.contains($0) }.joined(separator: ", ")
            throw OTodoError.validation(
                field: "projects",
                message: "Unknown project slug(s): \(unknown)"
            )
        }
    }

    private static func replacing(
        _ workspace: WorkspaceState,
        knownProjectSlugs: [String]? = nil,
        tasks: [TaskDocument],
        pendingChanges: [PendingChange],
        conflicts: [SyncConflict]
    ) throws -> WorkspaceState {
        guard workspace.revision < UInt64.max else {
            throw OTodoError.corruptLocalState(message: "Workspace revision cannot be incremented")
        }
        return try WorkspaceState(
            selection: workspace.selection,
            configuration: workspace.configuration,
            knownProjectSlugs: knownProjectSlugs ?? workspace.knownProjectSlugs,
            tasks: tasks,
            baseHeadCommitSHA: workspace.baseHeadCommitSHA,
            baseRootTreeSHA: workspace.baseRootTreeSHA,
            pendingChanges: pendingChanges,
            conflicts: conflicts,
            revision: workspace.revision + 1
        )
    }

    private static func repositoryPath(
        selection: RepositorySelection,
        storeRelativePath: String
    ) -> String {
        selection.storePath.isEmpty
            ? storeRelativePath
            : "\(selection.storePath)/\(storeRelativePath)"
    }

    private static func storeRelativePath(
        for repositoryPath: String,
        selection: RepositorySelection
    ) throws -> String {
        if selection.storePath.isEmpty {
            return repositoryPath
        }
        let prefix = selection.storePath + "/"
        guard repositoryPath.hasPrefix(prefix) else {
            throw OTodoError.validation(
                field: "conflict.path",
                message: "Conflict path is outside the selected store"
            )
        }
        return String(repositoryPath.dropFirst(prefix.count))
    }

    private static func taskID(
        for relativePath: String,
        configuration: StoreConfiguration
    ) throws -> TaskID {
        guard let id = try taskIDForCurrentLayout(
            relativePath,
            configuration: configuration
        ) else {
            throw OTodoError.validation(
                field: "conflict.path",
                message: "Conflict is not for a task document in the current task directory"
            )
        }
        return id
    }

    private static func taskIDForCurrentLayout(
        _ relativePath: String,
        configuration: StoreConfiguration
    ) throws -> TaskID? {
        let prefix = configuration.tasksDirectory + "/"
        guard relativePath.hasPrefix(prefix) else {
            return nil
        }
        let filename = String(relativePath.dropFirst(prefix.count))
        guard !filename.contains("/"), filename.hasSuffix(".md") else {
            return nil
        }
        let id = try TaskID(rawValue: String(filename.dropLast(3)))
        guard filename == "\(id.rawValue).md" else {
            return nil
        }
        return id
    }

    private static func taskIDFromBasename(for relativePath: String) throws -> TaskID {
        guard relativePath.hasSuffix(".md"),
              let filename = relativePath.split(separator: "/").last
        else {
            throw OTodoError.validation(
                field: "conflict.path",
                message: "Conflict is not for a task document"
            )
        }
        return try TaskID(rawValue: String(filename.dropLast(3)))
    }

    private static func replaceOrRemap(
        _ document: TaskDocument,
        in tasks: inout [TaskDocument]
    ) throws {
        if let pathIndex = tasks.firstIndex(where: {
            $0.task.relativePath == document.task.relativePath
        }) {
            guard tasks[pathIndex].task.id == document.task.id else {
                throw OTodoError.corruptLocalState(message: "Task path and identity disagree")
            }
            tasks[pathIndex] = document
        } else if let identityIndex = tasks.firstIndex(where: {
            $0.task.id == document.task.id
        }) {
            tasks[identityIndex] = document
        } else {
            tasks.append(document)
        }
    }

    private static func replaceOrInsert(
        _ document: TaskDocument,
        in tasks: inout [TaskDocument]
    ) throws {
        if let pathIndex = tasks.firstIndex(where: {
            $0.task.relativePath == document.task.relativePath
        }) {
            guard tasks[pathIndex].task.id == document.task.id else {
                throw OTodoError.corruptLocalState(message: "Task path and identity disagree")
            }
            tasks[pathIndex] = document
        } else {
            guard !tasks.contains(where: { $0.task.id == document.task.id }) else {
                throw OTodoError.corruptLocalState(message: "Task ID is already used by another path")
            }
            tasks.append(document)
        }
    }
}
