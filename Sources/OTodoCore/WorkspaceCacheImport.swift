import Foundation

extension WorkspaceState {
    /// Import only the derived task model. Raw documents, outbox entries and conflicts are immutable evidence.
    func importCacheRecords(legacyEnvelope: Bool) throws -> WorkspaceState {
        var imported: [TaskDocument] = []
        imported.reserveCapacity(tasks.count)
        for document in tasks {
            if configuration.schemaVersion == 1 {
                guard document.task.parentID == nil else {
                    throw OTodoError.corruptLocalState(message: "A schema-1 workspace cannot contain typed parent relationships")
                }
                imported.append(document)
                continue
            }
            let parsed = try ObsidianTaskCodec().parseTask(
                id: document.task.id, relativePath: document.task.relativePath,
                text: document.content, configuration: configuration
            )
            var reconciled = document.task
            let extra = reconciled.extraProperties.first { $0.name == "parent" }
            if let extra {
                guard legacyEnvelope, reconciled.parentID == nil,
                      case let .string(raw) = extra.value,
                      let parent = try? TaskID(rawValue: raw), parent == parsed.parentID else {
                    throw OTodoError.corruptLocalState(message: "Cached parent metadata disagrees with the schema-2 raw record")
                }
                reconciled.extraProperties.removeAll { $0.name == "parent" }
                reconciled.parentID = parent
            } else if legacyEnvelope, reconciled.parentID == nil {
                reconciled.parentID = parsed.parentID
            }
            guard reconciled.parentID == parsed.parentID else {
                throw OTodoError.corruptLocalState(message: "Cached typed parent disagrees with the raw record")
            }
            imported.append(TaskDocument(task: reconciled, content: document.content, blobSHA: document.blobSHA))
        }
        return try WorkspaceState(
            selection: selection, configuration: configuration, knownProjectSlugs: knownProjectSlugs,
            tasks: imported, baseHeadCommitSHA: baseHeadCommitSHA, baseRootTreeSHA: baseRootTreeSHA,
            pendingChanges: pendingChanges, conflicts: conflicts, revision: revision,
            relationshipBlocks: relationshipBlocks
        )
    }
}
