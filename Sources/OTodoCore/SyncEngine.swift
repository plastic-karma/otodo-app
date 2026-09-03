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
                    confirming: changesToPush
                )

                pulledCount += refreshed.pulledCount
                confirmedPendingIDs.formUnion(refreshed.confirmedPendingIDs)

                // A 409/422 with an unchanged head is not a stale-head race and must not be
                // turned into a blind retry. On an actual race, only retry paths from this
                // attempt whose original bases are still current.
                guard refreshedSnapshot.headCommitSHA != attemptedHead else {
                    throw error
                }
                let retryable = refreshed.safePendingChanges.filter { attemptedIDs.contains($0.id) }
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
        confirming confirmedAttempts: [PendingChange]
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
                confirming: confirmedAttemptsByPath
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
        confirming confirmedAttemptsByPath: [String: PendingChange] = [:]
    ) throws -> Reconciliation {
        let parsed = try parse(snapshot: snapshot, selection: selection)
        var tasksByPath = Dictionary(uniqueKeysWithValues: parsed.tasks.map { ($0.task.relativePath, $0) })
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
            try overlayTask(
                content: reconciledPending.content,
                fullPath: reconciledPending.path,
                blobSHA: reconciledPending.baseBlobSHA,
                selection: selection,
                configuration: parsed.configuration,
                tasksByPath: &tasksByPath
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
            try overlayTask(
                content: existing.localContent,
                fullPath: existing.path,
                blobSHA: existing.baseBlobSHA,
                selection: selection,
                configuration: parsed.configuration,
                tasksByPath: &tasksByPath
            )
        }

        let tasks = tasksByPath.values.sorted { $0.task.relativePath < $1.task.relativePath }
        try validateProjectReferences(
            tasks: tasks,
            knownProjectSlugs: parsed.knownProjectSlugs
        )

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
            knownProjectSlugs: parsed.knownProjectSlugs,
            tasks: tasks,
            baseHeadCommitSHA: snapshot.headCommitSHA,
            baseRootTreeSHA: snapshot.rootTreeSHA,
            pendingChanges: remainingPending,
            conflicts: conflicts,
            revision: nextRevision
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

    private func overlayTask(
        content: String,
        fullPath: String,
        blobSHA: String?,
        selection: RepositorySelection,
        configuration: StoreConfiguration,
        tasksByPath: inout [String: TaskDocument]
    ) throws {
        guard let relativePath = storeRelativePath(fullPath, storePath: selection.storePath),
              relativePath.hasPrefix(configuration.tasksDirectory + "/"),
              relativePath.hasSuffix(".md")
        else {
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
        tasksByPath[relativePath] = TaskDocument(task: task, content: content, blobSHA: blobSHA)
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
