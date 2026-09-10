import Foundation

public actor SyncEngine {
    private static let staleHeadRetryLimit = 2
    private static let workspaceSaveRetryLimit = 2
    private static let commitMessage = "Sync OTodo changes"

    private let attachmentStore: AttachmentStore?
    private let gitHub: any GitHubServing
    private let persistence: any WorkspacePersisting
    private let configCodec: any StoreConfigCoding
    private let taskCodec: any TaskRecordCoding

    public init(
        gitHub: any GitHubServing,
        persistence: any WorkspacePersisting,
        configCodec: any StoreConfigCoding,
        taskCodec: any TaskRecordCoding,
        attachmentStore: AttachmentStore? = nil
    ) {
        self.attachmentStore = attachmentStore
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

    /// Explicit, connected setup after user confirmation. Publishes only the shared configuration;
    /// task outbox entries remain ordinary offline edits and are never pushed by this operation.
    public func addInProgressState(selection: RepositorySelection) async throws -> WorkspaceState {
        let configPath = repositoryPath(storePath: selection.storePath, relativePath: ".todo/config.toml")
        _ = try await workspaceForConfigurationSetup(selection: selection, configPath: configPath)
        var snapshot = try await gitHub.fetchSnapshot(selection: selection)
        guard let configFile = snapshot.files.first(where: { $0.path == configPath }) else {
            throw OTodoError.notFound(resource: configPath)
        }
        let configuration = try configCodec.parseConfiguration(configFile.content)
        if let existing = configuration.states.first(where: { $0.id == WorkflowState.inProgress.id }) {
            guard existing.isInProgress else {
                throw OTodoError.conflict(
                    message: "The shared configuration already uses 'in-progress' for a terminal state. Resolve that state ID before enabling In Progress."
                )
            }
        } else {
            let newline = configFile.content.contains("\r\n") ? "\r\n" : "\n"
            let separator = configFile.content.hasSuffix("\n") ? newline : newline + newline
            let content = configFile.content + separator + [
                "[[states]]", "id = \"in-progress\"", "name = \"In Progress\"", "terminal = false", "",
            ].joined(separator: newline)
            _ = try configCodec.parseConfiguration(content)

            // Validate reconciliation before publishing, including pending local records and
            // schema-transition protections. The candidate is not saved or sent as a task edit.
            let candidate = try GitSnapshot(
                headCommitSHA: snapshot.headCommitSHA,
                rootTreeSHA: snapshot.rootTreeSHA,
                files: snapshot.files.map { file in
                    if file.path == configPath {
                        return try RemoteFile(path: configPath, blobSHA: file.blobSHA, content: content)
                    }
                    return file
                },
                attachments: snapshot.attachments
            )
            let local = try await workspaceForConfigurationSetup(selection: selection, configPath: configPath)
            let preview = try workspace(
                selection: selection, snapshot: candidate, pendingChanges: local.pendingChanges,
                existingConflicts: local.conflicts, previousWorkspace: local
            ).workspace
            guard preview.configuration.states.contains(where: \.isInProgress) else {
                throw OTodoError.conflict(
                    message: "Resolve the workspace's blocked schema transition before enabling In Progress."
                )
            }
            let commitSHA = try await gitHub.commit(
                selection: selection,
                changes: [try RemoteChange(path: configPath, content: content)],
                against: snapshot,
                message: "Enable In Progress workflow state"
            )
            _ = try await workspaceForConfigurationSetup(selection: selection, configPath: configPath)
            try await gitHub.updateReference(
                selection: selection, to: commitSHA, expectedHead: snapshot.headCommitSHA
            )
            snapshot = try await gitHub.fetchSnapshot(selection: selection)
        }

        guard try parse(snapshot: snapshot, selection: selection).configuration.states.contains(where: \.isInProgress) else {
            throw OTodoError.conflict(
                message: "The shared configuration changed during setup. Sync and review it before enabling In Progress again."
            )
        }
        _ = try await workspaceForConfigurationSetup(selection: selection, configPath: configPath)
        let refreshed = try await reconcileAndSave(selection: selection, snapshot: snapshot, confirming: []).workspace
        guard refreshed.configuration.states.contains(where: \.isInProgress) else {
            throw OTodoError.conflict(
                message: "In Progress is configured remotely, but a blocked schema transition prevents loading it. Resolve the workspace's schema transition and sync."
            )
        }
        return refreshed
    }

    private func workspaceForConfigurationSetup(
        selection: RepositorySelection, configPath: String
    ) async throws -> WorkspaceState {
        let local = try await loadWorkspace(selection: selection)
        guard !local.pendingChanges.contains(where: { $0.path == configPath }),
              !local.conflicts.contains(where: { $0.path == configPath }) else {
            throw OTodoError.conflict(
                message: "Resolve or sync the local .todo/config.toml change before enabling In Progress."
            )
        }
        return local
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
            var remoteChanges: [RemoteChange] = []
            for change in changesToPush.sorted(by: { $0.path < $1.path }) {
                if let binary = change.payload.binaryFile {
                    guard let attachmentStore else { throw OTodoError.corruptLocalState(message: "Attachment storage is unavailable") }
                    let bytes = try await attachmentStore.read(binary, selection: selection)
                    remoteChanges.append(try RemoteChange(path: change.path, content: nil, binaryContent: bytes))
                } else {
                    remoteChanges.append(try RemoteChange(path: change.path, content: change.content))
                }
            }
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
        let projects: [ProjectDocument]
        let filesByPath: [String: RemoteFile]
        let attachmentsByPath: [String: AttachmentMetadata]
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
                for pending in local.pendingChanges where reconciliation.confirmedPendingIDs.contains(pending.id) {
                    if let binary = pending.payload.binaryFile {
                        guard let attachmentStore else { throw OTodoError.corruptLocalState(message: "Cannot confirm attachment without retaining offline bytes") }
                        try await attachmentStore.retainVerified(binary, path: pending.path, selection: selection)
                    }
                }
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
                    revision: previousWorkspace.revision + 1, relationshipBlocks: blocked,
                    attachments: previousWorkspace.attachments, projects: previousWorkspace.projects
                )
                return Reconciliation(workspace: retained, safePendingChanges: [], confirmedPendingIDs: [], pulledCount: 0)
            }
        }
        let relocated = try remappingProjectLayout(
            pending: pendingChanges, conflicts: existingConflicts, selection: selection,
            previous: previousWorkspace?.configuration, current: parsed.configuration
        )
        let pendingChanges = relocated.pending
        let existingConflicts = relocated.conflicts
        var tasksByPath = Dictionary(uniqueKeysWithValues: parsed.tasks.map { ($0.task.relativePath, $0) })
        var projectsByPath = Dictionary(uniqueKeysWithValues: parsed.projects.map { ($0.project.relativePath, $0) })
        var knownProjectSlugs = Set(parsed.knownProjectSlugs)
        let existingConflictsByPath = Dictionary(uniqueKeysWithValues: existingConflicts.map { ($0.path, $0) })
        var reconciledConflicts: [SyncConflict] = []
        var safePendingChanges: [PendingChange] = []
        var remainingPending: [PendingChange] = []
        var confirmedPendingIDs: Set<UUID> = []
        let locallyProtectedPaths = Set(pendingChanges.map(\.path) + existingConflicts.map(\.path))
        let pendingPaths = Set(pendingChanges.map(\.path))

        for pending in pendingChanges {
            if let binary = pending.payload.binaryFile {
                let remote = parsed.attachmentsByPath[pending.path]
                if remote?.blobSHA == binary.blobSHA && remote?.isSymlink == false && remote?.isDirectory == false {
                    confirmedPendingIDs.insert(pending.id)
                    continue
                }
                remainingPending.append(pending)
                let unsafeAncestor = parsed.attachmentsByPath.values.contains { pending.path.hasPrefix($0.path + "/") && !$0.isDirectory }
                if remote == nil && !unsafeAncestor && existingConflictsByPath[pending.path] == nil && pending.baseBlobSHA == nil {
                    safePendingChanges.append(pending)
                } else {
                    reconciledConflicts.append(try SyncConflict(path: pending.path, baseBlobSHA: pending.baseBlobSHA,
                        remoteBlobSHA: remote?.blobSHA, localPayload: pending.payload,
                        remotePayload: remote.map(ChangePayload.remoteBinary) ?? .deletion))
                }
                continue
            }
            let remote = parsed.filesByPath[pending.path]
            if remote?.content == pending.content {
                confirmedPendingIDs.insert(pending.id)
                continue
            }

            // A coalesced edit retains the in-flight change's identity and old base. Once those
            // attempted bytes are remote, rebase only the newer bytes instead of conflicting.
            let reconciledPending: PendingChange
            if let confirmedAttempt = confirmedAttemptsByPath[pending.path]
                ?? relocated.originalPaths[pending.path].flatMap({ confirmedAttemptsByPath[$0] }),
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
                    createdAt: pending.createdAt,
                    groupID: pending.groupID
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
                knownProjectSlugs: &knownProjectSlugs,
                projectsByPath: &projectsByPath
            )
        }

        // A conflict normally has a matching pending change. Preserve an orphaned conflict
        // conservatively as well: it is durable user state and must never become pushable merely
        // because a partially-written local state omitted its outbox entry.
        for existing in existingConflicts where !pendingPaths.contains(existing.path) {
            if let binary = existing.localPayload.binaryFile {
                let remote = parsed.attachmentsByPath[existing.path]
                // Keep orphaned binary evidence until explicit resolution; its bytes remain protected.
                reconciledConflicts.append(try SyncConflict(path: existing.path, baseBlobSHA: existing.baseBlobSHA,
                    remoteBlobSHA: remote?.blobSHA, localPayload: .binaryFile(binary),
                    remotePayload: remote.map(ChangePayload.remoteBinary) ?? .deletion))
                continue
            }
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
                knownProjectSlugs: &knownProjectSlugs,
                projectsByPath: &projectsByPath
            )
        }

        let tasks = tasksByPath.values.sorted { $0.task.relativePath < $1.task.relativePath }
        let projects = knownProjectSlugs.sorted()
        try validateProjectReferences(
            tasks: tasks,
            knownProjectSlugs: projects
        )
        let relationshipResult = try dependencySafeChanges(
            candidates: safePendingChanges.filter { publishablePendingIDs?.contains($0.id) ?? true },
            pending: remainingPending, conflicts: reconciledConflicts, remote: parsed, localTasks: tasks, selection: selection
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
            relationshipBlocks: relationshipResult.blocks,
            attachments: snapshot.attachments,
            projects: projectsByPath.values.sorted { $0.project.relativePath < $1.project.relativePath }
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

    private func remappingProjectLayout(
        pending: [PendingChange], conflicts: [SyncConflict], selection: RepositorySelection,
        previous: StoreConfiguration?, current: StoreConfiguration
    ) throws -> (pending: [PendingChange], conflicts: [SyncConflict], originalPaths: [String: String]) {
        guard let previous, previous.projectsDirectory != current.projectsDirectory else {
            return (pending, conflicts, [:])
        }
        let oldPrefix = repositoryPath(storePath: selection.storePath, relativePath: previous.projectsDirectory + "/")
        let newPrefix = repositoryPath(storePath: selection.storePath, relativePath: current.projectsDirectory + "/")
        let occupied = Set(pending.map(\.path) + conflicts.map(\.path))
        var originalPaths: [String: String] = [:]
        func currentPath(for path: String) throws -> String {
            guard path.hasPrefix(oldPrefix), path.hasSuffix(".md") else { return path }
            let filename = String(path.dropFirst(oldPrefix.count))
            guard !filename.contains("/") else { return path }
            try DomainValidation.validateProjectSlugs([String(filename.dropLast(3))])
            let destination = newPrefix + filename
            guard !occupied.contains(destination) else {
                throw OTodoError.conflict(message: "Cannot move pending project to occupied path \(destination)")
            }
            originalPaths[destination] = path
            return destination
        }
        let relocatedPending = try pending.map { change in
            let path = try currentPath(for: change.path)
            guard path != change.path else { return change }
            return try PendingChange(id: change.id, path: path, baseBlobSHA: change.baseBlobSHA,
                payload: change.payload, createdAt: change.createdAt, groupID: change.groupID)
        }
        let relocatedConflicts = try conflicts.map { conflict in
            let path = try currentPath(for: conflict.path)
            guard path != conflict.path else { return conflict }
            return try SyncConflict(path: path, baseBlobSHA: conflict.baseBlobSHA,
                remoteBlobSHA: conflict.remoteBlobSHA, localPayload: conflict.localPayload,
                remotePayload: conflict.remotePayload)
        }
        return (relocatedPending, relocatedConflicts, originalPaths)
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

    /// Projects, attachments, parent relationships and durable groups are reduced together to a safe fixed point.
    private func dependencySafeChanges(candidates: [PendingChange], pending: [PendingChange], conflicts: [SyncConflict], remote: ParsedSnapshot,
        localTasks: [TaskDocument], selection: RepositorySelection) throws -> (changes: [PendingChange], blocks: [TaskRelationshipBlock]) {
        var safe = candidates
        var blocks: [TaskRelationshipBlock] = []
        if !AttachmentLinks.enabled(configuration: remote.configuration) { safe.removeAll { $0.payload.binaryFile != nil } }
        let imports = Set(pending.filter { $0.payload.binaryFile != nil }.map(\.path)
            + conflicts.filter { $0.localPayload.binaryFile != nil }.map(\.path))
        let taskByPath = Dictionary(uniqueKeysWithValues: localTasks.map {
            (repositoryPath(storePath: selection.storePath, relativePath: $0.task.relativePath), $0.task)
        })
        while true {
            let priorCount = safe.count
            let relationships = try relationshipSafeChanges(candidates: safe, remote: remote, localTasks: localTasks, selection: selection)
            safe = relationships.changes
            blocks.append(contentsOf: relationships.blocks)
            let projects = projectSafeChanges(candidates: safe, remote: remote, localTasksByPath: taskByPath, selection: selection)
            safe = projects.changes
            blocks.append(contentsOf: projects.blocks)
            let safePaths = Set(safe.map(\.path))
            safe = safe.filter { change in
                guard let task = taskByPath[change.path], change.content != nil else { return true }
                let needed = AttachmentLinks.references(body: task.body, taskPath: task.relativePath, storePrefix: remote.configuration.obsidianLinkPrefix).map {
                    repositoryPath(storePath: selection.storePath, relativePath: $0.path)
                }.filter { imports.contains($0) }
                guard needed.allSatisfy({ safePaths.contains($0) }) else {
                    blocks.append(TaskRelationshipBlock(path: change.path, code: "attachment_dependency",
                        message: "Task waits for a pending attachment import; resolve its conflict first", relatedTaskIDs: [task.id]))
                    return false
                }
                return true
            }
            let publishingTasks = Set(safe.compactMap { taskByPath[$0.path]?.id })
            safe = safe.filter { change in
                guard change.payload.binaryFile != nil else { return true }
                let dependents = localTasks.filter { document in
                    AttachmentLinks.references(body: document.task.body, taskPath: document.task.relativePath, storePrefix: remote.configuration.obsidianLinkPrefix).contains {
                        repositoryPath(storePath: selection.storePath, relativePath: $0.path) == change.path
                    }
                }
                // Every locally changed association must publish with its file. Unreferenced imports remain durable.
                return !dependents.isEmpty && dependents.allSatisfy { document in
                    let fullPath = repositoryPath(storePath: selection.storePath, relativePath: document.task.relativePath)
                    return !pending.contains(where: { $0.path == fullPath }) || publishingTasks.contains(document.task.id)
                }
            }
            let eligiblePaths = Set(safe.map(\.path))
            let blockedGroups = Set(pending.compactMap { change in
                eligiblePaths.contains(change.path) ? nil : change.groupID
            })
            safe.removeAll { change in
                change.groupID.map { blockedGroups.contains($0) } ?? false
            }
            if safe.count == priorCount { break }
        }
        var seen = Set<String>()
        return (safe, blocks.filter { seen.insert($0.path + $0.code + $0.message).inserted })
    }

    private func projectSafeChanges(
        candidates: [PendingChange], remote: ParsedSnapshot,
        localTasksByPath: [String: TodoTask], selection: RepositorySelection
    ) -> (changes: [PendingChange], blocks: [TaskRelationshipBlock]) {
        let prefix = repositoryPath(storePath: selection.storePath, relativePath: remote.configuration.projectsDirectory + "/")
        var available = Set(remote.knownProjectSlugs)
        var deletions: [String: String] = [:]
        for change in candidates where change.path.hasPrefix(prefix) && change.path.hasSuffix(".md") {
            let filename = String(change.path.dropFirst(prefix.count))
            guard !filename.contains("/") else { continue }
            let slug = String(filename.dropLast(3))
            if change.content == nil {
                available.remove(slug)
                deletions[slug] = change.path
            } else {
                available.insert(slug)
            }
        }
        var blocks: [TaskRelationshipBlock] = []
        var safe = candidates.filter { change in
            guard change.content != nil, let task = localTasksByPath[change.path] else { return true }
            guard task.projectSlugs.allSatisfy(available.contains) else {
                blocks.append(TaskRelationshipBlock(path: change.path, code: "project_dependency",
                    message: "Task waits for its project record to become publishable; resolve the project operation's conflict first",
                    relatedTaskIDs: [task.id]))
                return false
            }
            return true
        }
        if !deletions.isEmpty {
            let safeByPath = Dictionary(uniqueKeysWithValues: safe.map { ($0.path, $0) })
            var blockedDeletions = Set<String>()
            for document in remote.tasks where document.task.projectSlugs.contains(where: { deletions[$0] != nil }) {
                let path = repositoryPath(storePath: selection.storePath, relativePath: document.task.relativePath)
                let task: TodoTask
                if let change = safeByPath[path] {
                    guard change.content != nil, let replacement = localTasksByPath[path] else { continue }
                    task = replacement
                } else {
                    task = document.task
                }
                for slug in task.projectSlugs {
                    guard let deletionPath = deletions[slug] else { continue }
                    blockedDeletions.insert(deletionPath)
                    blocks.append(TaskRelationshipBlock(path: deletionPath, code: "project_dependency",
                        message: "Project deletion waits for its remaining task links to be removed",
                        relatedTaskIDs: [task.id]))
                }
            }
            safe.removeAll { blockedDeletions.contains($0.path) }
        }
        return (safe, blocks)
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
        let localByPath = Dictionary(uniqueKeysWithValues: localTasks.map { ($0.task.relativePath, $0) })
        while true {
            var publish = Dictionary(uniqueKeysWithValues: remote.tasks.map { ($0.task.relativePath, $0) })
            // Reconciliation already parsed every local record; project metadata is irrelevant to hierarchy.
            for change in safe {
                guard let relative = storeRelativePath(change.path, storePath: selection.storePath),
                      relative.hasPrefix(remote.configuration.tasksDirectory + "/"), relative.hasSuffix(".md") else { continue }
                publish[relative] = change.content == nil ? nil : localByPath[relative]
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
        var projects: [ProjectDocument] = []

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
                let slug = String(projectRelativePath.dropLast(3))
                let project = try ObsidianProjectCodec().parseProject(slug: slug, relativePath: relativePath, text: file.content)
                projectSlugs.append(slug)
                projects.append(ProjectDocument(project: project, content: file.content, blobSHA: file.blobSHA))
            }
        }

        tasks.sort { $0.task.relativePath < $1.task.relativePath }
        projectSlugs.sort()

        return ParsedSnapshot(
            configuration: configuration,
            knownProjectSlugs: projectSlugs,
            tasks: tasks,
            projects: projects.sorted { $0.project.relativePath < $1.project.relativePath },
            filesByPath: filesByPath,
            attachmentsByPath: Dictionary(uniqueKeysWithValues: snapshot.attachments.map { ($0.path, $0) })
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
        knownProjectSlugs: inout Set<String>,
        projectsByPath: inout [String: ProjectDocument]
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
        if let content {
            let project = try ObsidianProjectCodec().parseProject(slug: slug, relativePath: relativePath, text: content)
            knownProjectSlugs.insert(slug)
            projectsByPath[relativePath] = ProjectDocument(project: project, content: content, blobSHA: blobSHA)
        } else {
            knownProjectSlugs.remove(slug)
            projectsByPath.removeValue(forKey: relativePath)
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
