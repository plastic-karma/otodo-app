import Foundation
import XCTest
@testable import OTodoCore

final class ProjectCodecCacheTests: XCTestCase, @unchecked Sendable {
    func testArchiveRoundTripPreservesTypedOrderedExtrasAndExactBody() throws {
        let codec = ObsidianProjectCodec()
        let body = "\r\n# Notes\r\n[[Tasks/example]]  \nNo final newline"
        let source = "---\r\nname: 'Research: next'\r\nstate: {flag: true, count: 7}\r\nparent: [null, 'false', 2.5]\r\narchived: false\r\n---\r\n" + body
        let original = try codec.parseProject(slug: "research", relativePath: "Projects/research.md", text: source)
        var archived = original
        try archived.setArchived(true)
        let roundTrip = try codec.parseProject(slug: original.slug, relativePath: original.relativePath, text: codec.serializeProject(archived))
        XCTAssertTrue(roundTrip.isArchived)
        XCTAssertEqual(roundTrip.body, body)
        XCTAssertEqual(roundTrip.extraProperties.filter { $0.name != "archived" }, original.extraProperties.filter { $0.name != "archived" })
        var restored = roundTrip
        try restored.setArchived(false)
        XCTAssertFalse(restored.isArchived)
        XCTAssertEqual(restored.body, original.body)
        XCTAssertEqual(restored.name, original.name)
        XCTAssertEqual(try codec.parseProject(slug: restored.slug, relativePath: restored.relativePath, text: codec.serializeProject(restored)), restored)
    }

    func testKeywordKeysRemainStringsAcrossArchiveAndRestore() throws {
        let codec = ObsidianProjectCodec()
        let source = "---\nname: Alpha\n\"true\": keep\nnested: {\"FALSE\": 3, \"null\": value}\n---\nBody\n"
        let original = try codec.parseProject(slug: "alpha", relativePath: "Projects/alpha.md", text: source)
        var project = original
        try project.setArchived(true)
        project = try codec.parseProject(slug: project.slug, relativePath: project.relativePath,
                                         text: codec.serializeProject(project))
        try project.setArchived(false)
        let restored = try codec.parseProject(slug: project.slug, relativePath: project.relativePath,
                                              text: codec.serializeProject(project))
        XCTAssertEqual(restored.extraProperties, original.extraProperties)
        XCTAssertEqual(restored.body, original.body)
    }

    func testEmptyStringProjectKeysRoundTripWithoutBlockingWorkspaceRecords() throws {
        let codec = ObsidianProjectCodec()
        let source = "---\nname: Alpha\n\"\": {\"\": keep}\n---\nBody\n"
        var project = try codec.parseProject(slug: "alpha", relativePath: "Projects/alpha.md", text: source)
        let extras = project.extraProperties
        try project.setArchived(true)
        let archived = try codec.parseProject(slug: project.slug, relativePath: project.relativePath,
                                              text: codec.serializeProject(project))
        XCTAssertEqual(archived.extraProperties.filter { $0.name != "archived" }, extras)
        XCTAssertTrue(archived.isArchived)
    }

    func testPendingProjectEditWinsOverCachedProjectionBeforeArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try RepositorySelection(owner: "o", name: "pending-edit", branch: "main", storePath: "")
        let configuration = try StoreConfiguration(schemaVersion: 1, tasksDirectory: "Tasks", projectsDirectory: "Projects",
            obsidianLinkPrefix: "", defaultState: "open", states: [try WorkflowState(id: "open", name: "Open", isTerminal: false)])
        let codec = ObsidianProjectCodec()
        let oldText = "---\nname: Alpha\nplugin: old\n---\nOld notes\n"
        let pendingText = "---\nname: Renamed locally\nplugin: [latest, 7]\n---\nUnsynced notes  \r\n"
        let oldProject = try codec.parseProject(slug: "alpha", relativePath: "Projects/alpha.md", text: oldText)
        let expected = try codec.parseProject(slug: "alpha", relativePath: oldProject.relativePath, text: pendingText)
        let pending = try PendingChange(id: UUID(), path: oldProject.relativePath, baseBlobSHA: "base",
            content: pendingText, createdAt: Date(timeIntervalSince1970: 10))
        let workspace = try WorkspaceState(selection: selection, configuration: configuration, knownProjectSlugs: ["alpha"],
            tasks: [], baseHeadCommitSHA: "head", baseRootTreeSHA: "tree", pendingChanges: [pending], conflicts: [],
            projects: [ProjectDocument(project: oldProject, content: oldText, blobSHA: "base")])
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(workspace, expectedRevision: nil)
        let service = TaskWorkspaceService(persistence: store, taskCodec: ObsidianTaskCodec())
        let archived = try await service.archiveProject(selection: selection, slug: "alpha")
        let document = try XCTUnwrap(archived.projects.first)
        XCTAssertTrue(document.project.isArchived)
        XCTAssertEqual(document.project.name, expected.name)
        XCTAssertEqual(document.project.body, expected.body)
        XCTAssertEqual(document.project.extraProperties.filter { $0.name != "archived" }, expected.extraProperties)
        let reloadedValue = try await FileWorkspaceStore(rootURL: directory).load(selection: selection)
        XCTAssertEqual(try XCTUnwrap(reloadedValue).projects, archived.projects)
    }

    func testPendingProjectDeletionCannotBeResurrectedByArchivingCachedProjection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try RepositorySelection(owner: "o", name: "pending-delete", branch: "main", storePath: "")
        let configuration = try StoreConfiguration(schemaVersion: 1, tasksDirectory: "Tasks", projectsDirectory: "Projects",
            obsidianLinkPrefix: "", defaultState: "open", states: [try WorkflowState(id: "open", name: "Open", isTerminal: false)])
        let source = "---\nname: Alpha\n---\nOld notes\n"
        let project = try ObsidianProjectCodec().parseProject(slug: "alpha", relativePath: "Projects/alpha.md", text: source)
        let deletion = try PendingChange(id: UUID(), path: project.relativePath, baseBlobSHA: "base",
            content: nil, createdAt: Date(timeIntervalSince1970: 10))
        let workspace = try WorkspaceState(selection: selection, configuration: configuration, knownProjectSlugs: ["alpha"],
            tasks: [], baseHeadCommitSHA: "head", baseRootTreeSHA: "tree", pendingChanges: [deletion], conflicts: [],
            projects: [ProjectDocument(project: project, content: source, blobSHA: "base")])
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(workspace, expectedRevision: nil)
        let service = TaskWorkspaceService(persistence: store, taskCodec: ObsidianTaskCodec())
        do {
            _ = try await service.archiveProject(selection: selection, slug: "alpha")
            XCTFail("A pending project deletion must not become an archive write")
        } catch {
            let loadedValue = try await store.load(selection: selection)
            let loaded = try XCTUnwrap(loadedValue)
            XCTAssertFalse(loaded.knownProjectSlugs.contains("alpha"))
            XCTAssertTrue(loaded.projects.isEmpty)
            XCTAssertEqual(loaded.pendingChanges, [deletion])
        }
    }

    func testArchiveCollisionIsLosslessAndNeverCoerced() throws {
        let codec = ObsidianProjectCodec()
        for value in ["'true'", "1", "null", "[true]", "{flag: true}"] {
            var project = try codec.parseProject(slug: "alpha", relativePath: "Projects/alpha.md", text: "---\nname: Alpha\narchived: \(value)\n---\nBody\n")
            let original = project
            XCTAssertFalse(project.isArchived)
            XCTAssertThrowsError(try project.setArchived(true))
            XCTAssertEqual(project, original)
            XCTAssertThrowsError(try project.setArchived(false))
            XCTAssertEqual(try codec.parseProject(slug: project.slug, relativePath: project.relativePath, text: codec.serializeProject(project)), original)
        }
    }

    func testOnlyHistoricalSingleHeadingImportsWithoutFrontmatter() throws {
        let codec = ObsidianProjectCodec()
        let original = "# Human title\n"
        var project = try codec.parseProject(slug: "unrelated-slug", relativePath: "Projects/unrelated-slug.md", text: original)
        XCTAssertEqual(project.name, "Human title")
        XCTAssertEqual(project.body, original)
        try project.setArchived(true)
        let serialized = try codec.serializeProject(project)
        XCTAssertTrue(serialized.hasPrefix("---\n"))
        XCTAssertEqual(try codec.parseProject(slug: project.slug, relativePath: project.relativePath, text: serialized).body, original)
        for invalid in ["# Human title", "# Human title\n\n", "# Human title\nNotes\n", "# Human title\r\n", "#  Human title\n", "arbitrary prose\n", "---\narchived: true\n---\n", "---\nname: true\n---\n", "---\nname: Alpha\nname: Beta\n---\n", "---\nname: Alpha\nid: alpha\n---\n", "---\nname: Alpha\narchived: &value true\n---\n"] {
            XCTAssertThrowsError(try codec.parseProject(slug: "alpha", relativePath: "Projects/alpha.md", text: invalid), invalid)
        }
        XCTAssertThrowsError(try codec.parseProject(slug: "alpha", relativePath: "Projects/beta.md", text: original))
        XCTAssertThrowsError(try codec.parseProject(slug: "alpha", relativePath: "../alpha.md", text: original))
    }

    func testRealOldEnvelopesDoNotInventProjectDocumentsAndRecoverLocalEvidence() async throws {
        let selection = try RepositorySelection(owner: "o", name: "cache", branch: "main", storePath: "vault")
        let configuration = try StoreConfiguration(schemaVersion: 1, tasksDirectory: "Tasks", projectsDirectory: "Projects", obsidianLinkPrefix: "Vault", defaultState: "open", states: [try WorkflowState(id: "open", name: "Open", isTerminal: false)])
        let source = "# A real historical title\n"
        let orphanSource = "---\nname: Remote disagreement\narchived: 'plugin-owned'\n---\n\r\nKeep body  \r\n"
        let pending = try PendingChange(id: UUID(), path: "vault/Projects/alpha.md", baseBlobSHA: "base-alpha", content: source, createdAt: Date(timeIntervalSince1970: 10))
        let conflict = try SyncConflict(path: "vault/Projects/beta.md", baseBlobSHA: "base-beta", remoteBlobSHA: "remote-beta", localContent: orphanSource, remoteContent: "# Remote title\n")
        for version in 1...3 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let original = try WorkspaceState(selection: selection, configuration: configuration, knownProjectSlugs: ["alpha", "beta", "slug-only"], tasks: [], baseHeadCommitSHA: "head", baseRootTreeSHA: "tree", pendingChanges: [pending], conflicts: [conflict])
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            json.removeValue(forKey: "projects")
            let data = try JSONSerialization.data(withJSONObject: ["version": version, "workspace": json])
            try data.write(to: directory.appendingPathComponent(FileWorkspaceStore.selectionKey(for: selection) + ".json"))
            let loadedValue = try await FileWorkspaceStore(rootURL: directory).load(selection: selection)
            let loaded = try XCTUnwrap(loadedValue)
            XCTAssertEqual(loaded.knownProjectSlugs, ["alpha", "beta", "slug-only"])
            XCTAssertEqual(loaded.projects.map(\.project.slug), ["alpha", "beta"])
            XCTAssertEqual(loaded.projects.map(\.content), [source, orphanSource])
            XCTAssertEqual(loaded.projects.map(\.blobSHA), ["base-alpha", "base-beta"])
            XCTAssertEqual(loaded.projects[0].project.body, source)
            XCTAssertEqual(loaded.pendingChanges, [pending])
            XCTAssertEqual(loaded.conflicts, [conflict])
            let service = TaskWorkspaceService(persistence: FileWorkspaceStore(rootURL: directory), taskCodec: ObsidianTaskCodec())
            do {
                _ = try await service.archiveProject(selection: selection, slug: "slug-only")
                XCTFail("Slug-only cache must require real metadata before archival")
            } catch {
                let unchanged = try await FileWorkspaceStore(rootURL: directory).load(selection: selection)
                XCTAssertEqual(unchanged, loaded)
            }
        }
    }

    func testVersionFourRetainsAtomicGroupAcrossDiskReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try RepositorySelection(owner: "o", name: "groups", branch: "main", storePath: "")
        let configuration = try StoreConfiguration(schemaVersion: 1, tasksDirectory: "Tasks", projectsDirectory: "Projects", obsidianLinkPrefix: "", defaultState: "open", states: [try WorkflowState(id: "open", name: "Open", isTerminal: false)])
        let group = UUID()
        let source = "---\nname: Alpha\narchived: true\n---\n# Old heading\n"
        let project = try ObsidianProjectCodec().parseProject(slug: "alpha", relativePath: "Projects/alpha.md", text: source)
        let pending = try PendingChange(id: UUID(), path: project.relativePath, baseBlobSHA: "base", content: source, createdAt: Date(timeIntervalSince1970: 10), groupID: group)
        let workspace = try WorkspaceState(selection: selection, configuration: configuration, knownProjectSlugs: ["alpha"], tasks: [], baseHeadCommitSHA: "head", baseRootTreeSHA: "tree", pendingChanges: [pending], conflicts: [], projects: [ProjectDocument(project: project, content: source, blobSHA: "base")])
        try await FileWorkspaceStore(rootURL: directory).save(workspace, expectedRevision: nil)
        let loaded = try await FileWorkspaceStore(rootURL: directory).load(selection: selection)
        XCTAssertEqual(loaded, workspace)
        let data = try Data(contentsOf: directory.appendingPathComponent(FileWorkspaceStore.selectionKey(for: selection) + ".json"))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, 4)
    }

    func testCompleteCachedDocumentSurvivesSeparateDeletionConflictEvidence() throws {
        let selection = try RepositorySelection(owner: "o", name: "evidence", branch: "main", storePath: "")
        let configuration = try StoreConfiguration(schemaVersion: 1, tasksDirectory: "Tasks", projectsDirectory: "Projects", obsidianLinkPrefix: "", defaultState: "open", states: [try WorkflowState(id: "open", name: "Open", isTerminal: false)])
        let source = "---\nname: Real title\narchived: false\n---\nBody  \r\n"
        let project = try ObsidianProjectCodec().parseProject(slug: "alpha", relativePath: "Projects/alpha.md", text: source)
        let document = ProjectDocument(project: project, content: source, blobSHA: "cached-blob")
        let conflict = try SyncConflict(path: project.relativePath, baseBlobSHA: "older-base", remoteBlobSHA: "newer-remote",
            localContent: nil, remoteContent: "# Remote title\n")
        let workspace = try WorkspaceState(selection: selection, configuration: configuration,
            knownProjectSlugs: ["alpha"], tasks: [], baseHeadCommitSHA: "head", baseRootTreeSHA: "tree",
            pendingChanges: [], conflicts: [conflict], projects: [document])
        let imported = try workspace.importCacheRecords(legacyEnvelope: false)
        XCTAssertEqual(imported, workspace)
    }
}
