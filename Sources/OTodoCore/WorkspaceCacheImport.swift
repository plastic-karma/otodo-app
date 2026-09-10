import Foundation

extension WorkspaceState {
    /// Import derived models only. Raw documents, outbox entries and conflicts remain immutable evidence.
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
        let projectCodec = ObsidianProjectCodec()
        var projectsByPath: [String: ProjectDocument] = [:]
        var projectSlugs = Set(knownProjectSlugs)
        for document in projects {
            let parsed = try projectCodec.parseProject(slug: document.project.slug,
                relativePath: document.project.relativePath, text: document.content)
            guard parsed == document.project else {
                throw OTodoError.corruptLocalState(message: "Cached project metadata disagrees with its raw record")
            }
            projectsByPath[parsed.relativePath] = document
        }
        let storePrefix = selection.storePath.isEmpty ? "" : selection.storePath + "/"
        let projectPrefix = storePrefix + configuration.projectsDirectory + "/"
        let pendingPaths = Set(pendingChanges.map(\.path))
        let evidence = pendingChanges.map { ($0.path, $0.content, $0.baseBlobSHA, true) }
            + conflicts.filter { !pendingPaths.contains($0.path) }.map { ($0.path, $0.localContent, $0.baseBlobSHA, false) }
        for (path, content, sha, isPending) in evidence where path.hasPrefix(projectPrefix) && path.hasSuffix(".md") {
            let filename = String(path.dropFirst(projectPrefix.count))
            guard !filename.contains("/") else {
                throw OTodoError.corruptLocalState(message: "Nested cached project record is not supported")
            }
            let slug = String(filename.dropLast(3))
            let relativePath = String(path.dropFirst(storePrefix.count))
            // Pending bytes are authoritative; orphan conflicts only recover missing projections.
            if !isPending, projectsByPath[relativePath] != nil { continue }
            if let document = projectsByPath[relativePath], document.content == content, document.blobSHA == sha { continue }
            if let content {
                let project = try projectCodec.parseProject(slug: slug, relativePath: relativePath, text: content)
                projectsByPath[relativePath] = ProjectDocument(project: project, content: content, blobSHA: sha)
                projectSlugs.insert(slug)
            } else {
                projectsByPath.removeValue(forKey: relativePath)
                projectSlugs.remove(slug)
            }
        }
        return try WorkspaceState(
            selection: selection, configuration: configuration, knownProjectSlugs: projectSlugs.sorted(),
            tasks: imported, baseHeadCommitSHA: baseHeadCommitSHA, baseRootTreeSHA: baseRootTreeSHA,
            pendingChanges: pendingChanges, conflicts: conflicts, revision: revision,
            relationshipBlocks: relationshipBlocks, attachments: attachments,
            projects: projectsByPath.values.sorted { $0.project.relativePath < $1.project.relativePath }
        )
    }
}
