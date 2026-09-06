import Foundation

public actor SyncEngine {
    private static let staleHeadRetryLimit = 2
    private static let workspaceSaveRetryLimit = 2
    private static let commitMessage = "Sync OTodo changes"

    private let gitHub: any GitHubServing
    private let persistence: any WorkspacePersisting
    private let configCodec: any StoreConfigCoding
    private let taskCodec: any TaskRecordCoding

    public init(
        gitHub: any GitHubServing,
        persistence: any WorkspacePersisting,
        configCodec: any StoreConfigCoding,
        taskCodec: any TaskRecordCoding
    ) {
        self.gitHub = gitHub
        self.persistence = persistence
        self.configCodec = configCodec
        self.taskCodec = taskCodec
    }

    /// Fetches and validates a selected store before making it the durable local workspace.
    public func initialPull(selection: RepositorySelection) async throws -> WorkspaceState {
        guard try await persistence.load(selection: selection) == nil else {
            throw OTodoError.conflict(message: "A local workspace already exists for this repository selection")
        }

        let snapshot = try await gitHub.fetchSnapshot(selection: selection)
        let workspace = try workspace(
            selection: selection,
            snapshot: snapshot,
            pendingChanges: [],
            existingConflicts: [],
            previousWorkspace: nil
        ).workspace

        try await persistence.save(workspace, expectedRevision: nil)
        return workspace
    }

    /// Pulls the latest selected snapshot, replays safe local changes, and advances the branch
    /// only with a non-forced compare-and-swap update performed by `GitHubServing`.
    public func sync(selection: RepositorySelection) async throws -> SyncReport {
        _ = try await loadWorkspace(selection: selection)
        var snapshot = try await gitHub.fetchSnapshot(selection: selection)

        let reconciliation = try await reconcileAndSave(
            selection: selection,
            snapshot: snapshot,
            confirming: []
        )

        var pulledCount = reconciliation.pulledCount
        var confirmedPendingIDs = reconciliation.confirmedPendingIDs
        var changesToPush = reconciliation.safePendingChanges
        var staleRetriesRemaining = Self.staleHeadRetryLimit

        while !changesToPush.isEmpty {
            let remoteChanges = try changesToPush
                .sorted { $0.path < $1.path }
                .map { try RemoteChange(path: $0.path, content: $0.content) }
            let attemptedIDs = Set(changesToPush.map(\.id))
            let attemptedHead = snapshot.headCommitSHA
            let commitSHA = try await gitHub.commit(
                selection: selection,
                changes: remoteChanges,
                against: snapshot,
                message: Self.commitMessage
            )

            do {
                try await gitHub.updateReference(
                    selection: selection,
                    to: commitSHA,
                    expectedHead: attemptedHead
                )
            } catch let error as OTodoError {
                guard case .conflict = error else {
                    throw error
                }

                let refreshedSnapshot = try await gitHub.fetchSnapshot(selection: selection)
                let refreshed = try await reconcileAndSave(
                    selection: selection,
                    snapshot: refreshedSnapshot,
                    confirming: changesToPush,
                    restrictingTo: attemptedIDs
                )

                pulledCount += refreshed.pulledCount
                confirmedPendingIDs.formUnion(refreshed.confirmedPendingIDs)

                // A 409/422 with an unchanged head is not a stale-head race and must not be
                // turned into a blind retry. On an actual race, only retry paths from this
                // attempt whose original bases are still current.
                guard refreshedSnapshot.headCommitSHA != attemptedHead else {
                    throw error
                }
                let retryable = refreshed.safePendingChanges
                if retryable.isEmpty {
                    return try SyncReport(
                        pulledCount: pulledCount,
                        pushedCount: confirmedPendingIDs.count,
                        conflicts: refreshed.workspace.conflicts
                    )
                }
                guard staleRetriesRemaining > 0 else {
                    throw error
                }

                staleRetriesRemaining -= 1
                snapshot = refreshedSnapshot
                changesToPush = retryable
                continue
            }

            // The ref update can succeed and the process can stop before this confirmation.
            // A later run reaches the same path because reconciliation recognizes identical
            // remote content as an already-applied pending change.
            let confirmedSnapshot = try await gitHub.fetchSnapshot(selection: selection)
            let confirmed = try await reconcileAndSave(
                selection: selection,
                snapshot: confirmedSnapshot,
                confirming: changesToPush
            )

            pulledCount += confirmed.pulledCount
            confirmedPendingIDs.formUnion(confirmed.confirmedPendingIDs)
            return try SyncReport(
                pulledCount: pulledCount,
                pushedCount: confirmedPendingIDs.count,
                conflicts: confirmed.workspace.conflicts
            )
        }

        return try SyncReport(
            pulledCount: pulledCount,
            pushedCount: confirmedPendingIDs.count,
            conflicts: reconciliation.workspace.conflicts
        )
    }

    private struct Reconciliation {
        let workspace: WorkspaceState
        let safePendingChanges: [PendingChange]
        let confirmedPendingIDs: Set<UUID>
        let pulledCount: Int
    }

    private struct ParsedSnapshot {
        let configuration: StoreConfiguration
        let knownProjectSlugs: [String]
        let tasks: [TaskDocument]
        let filesByPath: [String: RemoteFile]
    }

    private func loadWorkspace(selection: RepositorySelection) async throws -> WorkspaceState {
        guard let workspace = try await persistence.load(selection: selection) else {
            throw OTodoError.notFound(resource: "local workspace")
        }
        guard workspace.selection == selection else {
            throw OTodoError.corruptLocalState(
                message: "The persistence layer returned a workspace for a different repository selection"
            )
        }
        return workspace
    }

    private func reconcileAndSave(
        selection: RepositorySelection,
        snapshot: GitSnapshot,
        confirming confirmedAttempts: [PendingChange],
        restrictingTo publishablePendingIDs: Set<UUID>? = nil
    ) async throws -> Reconciliation {
        var retriesRemaining = Self.workspaceSaveRetryLimit
        var confirmedAttemptsByPath = Dictionary(
            uniqueKeysWithValues: confirmedAttempts.map { ($0.path, $0) }
        )

        while true {
            let local = try await loadWorkspace(selection: selection)
            let reconciliation = try workspace(
                selection: selection,
                snapshot: snapshot,
                pendingChanges: local.pendingChanges,
                existingConflicts: local.conflicts,
                previousWorkspace: local,
                confirming: confirmedAttemptsByPath,
                restrictingTo: publishablePendingIDs
            )

            do {
                try await persistence.save(
                    reconciliation.workspace,
                    expectedRevision: local.revision
                )
                return reconciliation
            } catch let error as OTodoError {
                guard case .conflict = error, retriesRemaining > 0 else {
                    throw error
                }
                // The failed candidate may have confirmed an older version that was coalesced
                // by the concurrent save. Preserve that proof for the retry's rebase.
                for pending in local.pendingChanges where reconciliation.confirmedPendingIDs.contains(pending.id) {
                    confirmedAttemptsByPath[pending.path] = pending
                }
                retriesRemaining -= 1
            }
        }
    }

    private func workspace(
        selection: RepositorySelection,
        snapshot: GitSnapshot,
        pendingChanges: [PendingChange],
        existingConflicts: [SyncConflict],
        previousWorkspace: WorkspaceState?,
        confirming confirmedAttemptsByPath: [String: PendingChange] = [:],
        restrictingTo publishablePendingIDs: Set<UUID>? = nil
    ) throws -> Reconciliation {
        let parsed = try parse(snapshot: snapshot, selection: selection)
        if let previousWorkspace, previousWorkspace.configuration.schemaVersion > parsed.configuration.schemaVersion {
            throw OTodoError.validation(field: "schema_version", message: "unsupported_schema: Store schema downgrade is not supported")
        }
        if let previousWorkspace,
           previousWorkspace.configuration.schemaVersion == 1, parsed.configuration.schemaVersion == 2 {
            let blocked = try legacyParentTransitionBlocks(
                workspace: previousWorkspace, pendingChanges: pendingChanges, conflicts: existingConflicts
            )
            if !blocked.isEmpty {
                guard previousWorkspace.revision < UInt64.max else {
                    throw OTodoError.corruptLocalState(message: "Workspace revision cannot be incremented")
                }
                let retained = try WorkspaceState(
                    selection: selection, configuration: previousWorkspace.configuration,
                    knownProjectSlugs: previousWorkspace.knownProjectSlugs, tasks: previousWorkspace.tasks,
                    baseHeadCommitSHA: previousWorkspace.baseHeadCommitSHA,
                    baseRootTreeSHA: previousWorkspace.baseRootTreeSHA,
                    pendingChanges: pendingChanges, conflicts: existingConflicts,
                    revision: previousWorkspace.revision + 1, relationshipBlocks: blocked
                )
                return Reconciliation(workspace: retained, safePendingChanges: [], confirmedPendingIDs: [], pulledCount: 0)
            }
        }
        var tasksByPath = Dictionary(uniqueKeysWithValues: parsed.tasks.map { ($0.task.relativePath, $0) })
        var knownProjectSlugs = Set(parsed.knownProjectSlugs)
        let existingConflictsByPath = Dictionary(uniqueKeysWithValues: existingConflicts.map { ($0.path, $0) })
        var reconciledConflicts: [SyncConflict] = []
        var safePendingChanges: [PendingChange] = []
        var remainingPending: [PendingChange] = []
        var confirmedPendingIDs: Set<UUID> = []
        let locallyProtectedPaths = Set(pendingChanges.map(\.path) + existingConflicts.map(\.path))
        let pendingPaths = Set(pendingChanges.map(\.path))

        for pending in pendingChanges {
            let remote = parsed.filesByPath[pending.path]
            if remote?.content == pending.content {
                confirmedPendingIDs.insert(pending.id)
                continue
            }

            // A coalesced edit retains the in-flight change's identity and old base. Once those
            // attempted bytes are remote, rebase only the newer bytes instead of conflicting.
            let reconciledPending: PendingChange
            if let confirmedAttempt = confirmedAttemptsByPath[pending.path],
               confirmedAttempt.id == pending.id,
               confirmedAttempt.content != pending.content,
               let remote,
               remote.content == confirmedAttempt.content
            {
                reconciledPending = try PendingChange(
                    id: pending.id,
                    path: pending.path,
                    baseBlobSHA: remote.blobSHA,
                    content: pending.content,
                    createdAt: pending.createdAt
                )
                safePendingChanges.append(reconciledPending)
            } else {
                reconciledPending = pending
                if existingConflictsByPath[pending.path] != nil {
                    reconciledConflicts.append(try conflict(for: pending, remote: remote))
                } else if baseMatches(pending: pending, remote: remote) {
                    safePendingChanges.append(pending)
                } else {
                    reconciledConflicts.append(try conflict(for: pending, remote: remote))
                }
            }

            remainingPending.append(reconciledPending)
            try overlayChange(
                content: reconciledPending.content,
                fullPath: reconciledPending.path,
                blobSHA: reconciledPending.baseBlobSHA,
                selection: selection,
                configuration: parsed.configuration,
                tasksByPath: &tasksByPath,
                knownProjectSlugs: &knownProjectSlugs
            )
        }

        // A conflict normally has a matching pending change. Preserve an orphaned conflict
        // conservatively as well: it is durable user state and must never become pushable merely
        // because a partially-written local state omitted its outbox entry.
        for existing in existingConflicts where !pendingPaths.contains(existing.path) {
            let remote = parsed.filesByPath[existing.path]
            if remote?.content == existing.localContent {
                continue
            }
            let refreshed = try SyncConflict(
                path: existing.path,
                baseBlobSHA: existing.baseBlobSHA,
                remoteBlobSHA: remote?.blobSHA,
                localContent: existing.localContent,
                remoteContent: remote?.content
            )
            reconciledConflicts.append(refreshed)
            try overlayChange(
                content: existing.localContent,
                fullPath: existing.path,
                blobSHA: existing.baseBlobSHA,
                selection: selection,
                configuration: parsed.configuration,
                tasksByPath: &tasksByPath,
                knownProjectSlugs: &knownProjectSlugs
            )
        }

        let tasks = tasksByPath.values.sorted { $0.task.relativePath < $1.task.relativePath }
        let projects = knownProjectSlugs.sorted()
        try validateProjectReferences(
            tasks: tasks,
            knownProjectSlugs: projects
        )
        let relationshipResult = try relationshipSafeChanges(
            candidates: safePendingChanges.filter { publishablePendingIDs?.contains($0.id) ?? true },
            remote: parsed, localTasks: tasks,
            selection: selection
        )
        safePendingChanges = relationshipResult.changes

        let conflicts = reconciledConflicts.sorted { $0.path < $1.path }
        let nextRevision: UInt64
        if let previousWorkspace {
            guard previousWorkspace.revision < UInt64.max else {
                throw OTodoError.corruptLocalState(
                    message: "Workspace revision cannot be incremented"
                )
            }
            nextRevision = previousWorkspace.revision + 1
        } else {
            nextRevision = 0
        }
        let reconciledWorkspace = try WorkspaceState(
            selection: selection,
            configuration: parsed.configuration,
            knownProjectSlugs: projects,
            tasks: tasks,
            baseHeadCommitSHA: snapshot.headCommitSHA,
            baseRootTreeSHA: snapshot.rootTreeSHA,
            pendingChanges: remainingPending,
            conflicts: conflicts,
            revision: nextRevision,
            relationshipBlocks: relationshipResult.blocks
        )
        let pulledCount = previousWorkspace.map {
            changedTaskCount(
                from: $0.tasks,
                to: tasks,
                excludingFullPaths: locallyProtectedPaths,
                selection: selection
            )
        } ?? 0

        return Reconciliation(
            workspace: reconciledWorkspace,
            safePendingChanges: safePendingChanges,
            confirmedPendingIDs: confirmedPendingIDs,
            pulledCount: pulledCount
        )
    }

    private func legacyParentTransitionBlocks(
        workspace: WorkspaceState, pendingChanges: [PendingChange], conflicts: [SyncConflict]
    ) throws -> [TaskRelationshipBlock] {
        var result: [TaskRelationshipBlock] = []
        let versions = pendingChanges.map { ($0.path, $0.content) } + conflicts.map { ($0.path, $0.localContent) }
        var visited: Set<String> = []
        for (path, content) in versions {
            guard let content, visited.insert(path).inserted,
                  let relativePath = storeRelativePath(path, storePath: workspace.selection.storePath),
                  relativePath.hasPrefix(workspace.configuration.tasksDirectory + "/"),
                  relativePath.hasSuffix(".md"),
                  let filename = relativePath.split(separator: "/").last else { continue }
            let id = try TaskID(rawValue: String(filename.dropLast(3)))
            let task = try taskCodec.parseTask(id: id, relativePath: relativePath, text: content,
                                               configuration: workspace.configuration)
            if task.extraProperties.contains(where: { $0.name == "parent" }) {
                result.append(TaskRelationshipBlock(
                    path: path, code: "unsupported_schema",
                    message: "Schema activation is blocked by pending legacy parent metadata. Safeguard and explicitly relocate that metadata before upgrading.",
                    relatedTaskIDs: [id]
                ))
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private func relationshipSafeChanges(
        candidates: [PendingChange], remote: ParsedSnapshot, localTasks: [TaskDocument],
        selection: RepositorySelection
    ) throws -> (changes: [PendingChange], blocks: [TaskRelationshipBlock]) {
        let remoteTasks = remote.tasks.map(\.task)
        let local = localTasks.map(\.task)
        let allEdges = remoteTasks + local
        var blocks = TaskHierarchy.blocks(tasks: remoteTasks, storePath: selection.storePath)
        let localBlocks = TaskHierarchy.blocks(tasks: local, storePath: selection.storePath)
        blocks.append(contentsOf: localBlocks)
        var safe = candidates
        var neighbors: [TaskID: Set<TaskID>] = [:]
        for task in allEdges {
            if let parent = task.parentID {
                neighbors[task.id, default: []].insert(parent)
                neighbors[parent, default: []].insert(task.id)
            }
        }

        func withholding(_ issues: [TaskRelationshipBlock], from changes: [PendingChange]) -> [PendingChange] {
            guard !issues.isEmpty else { return changes }
            var reasons: [TaskID: TaskRelationshipBlock] = [:]
            for issue in issues {
                guard let seed = issue.relatedTaskIDs.first, reasons[seed] == nil else { continue }
                var related: Set<TaskID> = [seed]
                var stack = [seed]
                while let id = stack.popLast() {
                    for neighbor in neighbors[id] ?? [] where related.insert(neighbor).inserted {
                        stack.append(neighbor)
                    }
                }
                let reason = TaskRelationshipBlock(
                    path: issue.path, code: issue.code, message: issue.message, relatedTaskIDs: related.sorted()
                )
                for id in related { reasons[id] = reason }
            }
            return changes.filter { change in
                guard let relative = storeRelativePath(change.path, storePath: selection.storePath),
                      relative.hasPrefix(remote.configuration.tasksDirectory + "/"), relative.hasSuffix(".md"),
                      let filename = relative.split(separator: "/").last,
                      let id = try? TaskID(rawValue: String(filename.dropLast(3))),
                      let issue = reasons[id] else { return true }
                blocks.append(TaskRelationshipBlock(
                    path: change.path, code: issue.code,
                    message: "Pending relationship component is withheld: \(issue.message)",
                    relatedTaskIDs: issue.relatedTaskIDs
                ))
                return false
            }
        }

        safe = withholding(localBlocks, from: safe)
        while true {
            var publish = Dictionary(uniqueKeysWithValues: remote.tasks.map { ($0.task.relativePath, $0) })
            var projects = Set(remote.knownProjectSlugs)
            for change in safe {
                try overlayChange(
                    content: change.content, fullPath: change.path, blobSHA: change.baseBlobSHA,
                    selection: selection, configuration: remote.configuration,
                    tasksByPath: &publish, knownProjectSlugs: &projects
                )
            }
            let publishBlocks = TaskHierarchy.blocks(tasks: publish.values.map(\.task), storePath: selection.storePath)
            blocks.append(contentsOf: publishBlocks)
            let reduced = withholding(publishBlocks, from: safe)
            if reduced.count == safe.count { break }
            safe = reduced
        }
        var seen: Set<String> = []
        blocks = blocks.filter { seen.insert($0.path + "\u{0}" + $0.code + "\u{0}" + $0.message).inserted }
        blocks.sort { $0.path == $1.path ? $0.code < $1.code : $0.path < $1.path }
        return (safe, blocks)
    }

    private func parse(snapshot: GitSnapshot, selection: RepositorySelection) throws -> ParsedSnapshot {
        let filesByPath = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, $0) })
        let configPath = repositoryPath(storePath: selection.storePath, relativePath: ".todo/config.toml")
        guard let configFile = filesByPath[configPath] else {
            throw OTodoError.notFound(resource: configPath)
        }
        let configuration = try configCodec.parseConfiguration(configFile.content)
        let taskDirectory = configuration.tasksDirectory
        let projectDirectory = configuration.projectsDirectory

        var tasks: [TaskDocument] = []
        var projectSlugs: [String] = []

        for file in snapshot.files {
            guard let relativePath = storeRelativePath(file.path, storePath: selection.storePath) else {
                continue
            }

            if relativePath.hasPrefix(taskDirectory + "/"), relativePath.hasSuffix(".md") {
                let filename = relativePath.split(separator: "/").last.map(String.init) ?? ""
                let id = try TaskID(rawValue: String(filename.dropLast(3)))
                let task = try taskCodec.parseTask(
                    id: id,
                    relativePath: relativePath,
                    text: file.content,
                    configuration: configuration
                )
                tasks.append(TaskDocument(task: task, content: file.content, blobSHA: file.blobSHA))
                continue
            }

            if relativePath.hasPrefix(projectDirectory + "/"), relativePath.hasSuffix(".md") {
                let projectRelativePath = String(relativePath.dropFirst(projectDirectory.count + 1))
                guard !projectRelativePath.contains("/") else {
                    throw OTodoError.validation(
                        field: "project.path",
                        message: "Nested project record is not supported: \(relativePath)"
                    )
                }
                projectSlugs.append(String(projectRelativePath.dropLast(3)))
            }
        }

        tasks.sort { $0.task.relativePath < $1.task.relativePath }
        projectSlugs.sort()

        return ParsedSnapshot(
            configuration: configuration,
            knownProjectSlugs: projectSlugs,
            tasks: tasks,
            filesByPath: filesByPath
        )
    }

    private func baseMatches(pending: PendingChange, remote: RemoteFile?) -> Bool {
        switch (pending.baseBlobSHA, remote?.blobSHA) {
        case (nil, nil):
            true
        case let (base?, remoteSHA?):
            base == remoteSHA
        default:
            false
        }
    }

    private func conflict(for pending: PendingChange, remote: RemoteFile?) throws -> SyncConflict {
        try SyncConflict(
            path: pending.path,
            baseBlobSHA: pending.baseBlobSHA,
            remoteBlobSHA: remote?.blobSHA,
            localContent: pending.content,
            remoteContent: remote?.content
        )
    }

    private func overlayChange(
        content: String?,
        fullPath: String,
        blobSHA: String?,
        selection: RepositorySelection,
        configuration: StoreConfiguration,
        tasksByPath: inout [String: TaskDocument],
        knownProjectSlugs: inout Set<String>
    ) throws {
        guard let relativePath = storeRelativePath(fullPath, storePath: selection.storePath) else {
            return
        }

        if relativePath.hasPrefix(configuration.tasksDirectory + "/"),
           relativePath.hasSuffix(".md")
        {
            guard let content else {
                tasksByPath.removeValue(forKey: relativePath)
                return
            }

            let filename = relativePath.split(separator: "/").last.map(String.init) ?? ""
            let id = try TaskID(rawValue: String(filename.dropLast(3)))
            let task = try taskCodec.parseTask(
                id: id,
                relativePath: relativePath,
                text: content,
                configuration: configuration
            )
            tasksByPath[relativePath] = TaskDocument(
                task: task,
                content: content,
                blobSHA: blobSHA
            )
            return
        }

        let projectPrefix = configuration.projectsDirectory + "/"
        guard relativePath.hasPrefix(projectPrefix), relativePath.hasSuffix(".md") else {
            return
        }
        let projectRelativePath = String(relativePath.dropFirst(projectPrefix.count))
        guard !projectRelativePath.contains("/") else {
            throw OTodoError.validation(
                field: "project.path",
                message: "Nested project record is not supported: \(relativePath)"
            )
        }
        let slug = String(projectRelativePath.dropLast(3))
        if content == nil {
            knownProjectSlugs.remove(slug)
        } else {
            knownProjectSlugs.insert(slug)
        }
    }

    private func validateProjectReferences(
        tasks: [TaskDocument],
        knownProjectSlugs: [String]
    ) throws {
        let known = Set(knownProjectSlugs)
        for document in tasks {
            let missing = Set(document.task.projectSlugs).subtracting(known).sorted()
            guard missing.isEmpty else {
                throw OTodoError.validation(
                    field: "projects",
                    message: "Task \(document.task.id.rawValue) references missing project(s): \(missing.joined(separator: ", "))"
                )
            }
        }
    }

    private func changedTaskCount(
        from oldTasks: [TaskDocument],
        to newTasks: [TaskDocument],
        excludingFullPaths: Set<String>,
        selection: RepositorySelection
    ) -> Int {
        let excluded = Set(excludingFullPaths.compactMap {
            storeRelativePath($0, storePath: selection.storePath)
        })
        let oldByPath = Dictionary(uniqueKeysWithValues: oldTasks.map { ($0.task.relativePath, $0) })
        let newByPath = Dictionary(uniqueKeysWithValues: newTasks.map { ($0.task.relativePath, $0) })
        let paths = Set(oldByPath.keys).union(newByPath.keys).subtracting(excluded)
        return paths.reduce(into: 0) { count, path in
            if oldByPath[path] != newByPath[path] {
                count += 1
            }
        }
    }

    private func repositoryPath(storePath: String, relativePath: String) -> String {
        storePath.isEmpty ? relativePath : storePath + "/" + relativePath
    }

    private func storeRelativePath(_ fullPath: String, storePath: String) -> String? {
        guard !storePath.isEmpty else {
            return fullPath
        }
        let prefix = storePath + "/"
        guard fullPath.hasPrefix(prefix) else {
            return nil
        }
        return String(fullPath.dropFirst(prefix.count))
    }
}
