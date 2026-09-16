import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OTodoCore

final class LocalWorkspaceTests: XCTestCase, @unchecked Sendable {
    func testLegacyGitHubSelectionAndVersionFourKeyRemainReadable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = Data(#"{"owner":"example","name":"vault","branch":"main","storePath":"/Todo/"}"#.utf8)
        let selection = try JSONDecoder().decode(WorkspaceSelection.self, from: legacy)
        XCTAssertEqual(try selection.requireGitHub().storePath, "Todo")
        let key = "af17a17ff7d8385bb67fc03afb2f8e2518566c6503ef1e5dad6fb86d2d25a195"
        XCTAssertEqual(FileWorkspaceStore.selectionKey(for: selection), key)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as? [String: String])
        XCTAssertEqual(encoded, ["owner": "example", "name": "vault", "branch": "main", "storePath": "Todo"])

        let local = try await TaskWorkspaceService(persistence: FileWorkspaceStore(rootURL: directory), taskCodec: ObsidianTaskCodec()).createLocalWorkspace()
        let remote = try WorkspaceState(selection: selection, configuration: local.configuration, tasks: [],
                                        baseHeadCommitSHA: "existing-head", baseRootTreeSHA: "existing-tree", pendingChanges: [], conflicts: [])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(remote)) as? [String: Any])
        object.removeValue(forKey: "localAttachmentFiles")
        let fixture = try JSONSerialization.data(withJSONObject: ["version": 4, "workspace": object])
        try fixture.write(to: directory.appendingPathComponent(key + ".json"))
        let restored = try await FileWorkspaceStore(rootURL: directory).load(selection: selection)
        XCTAssertEqual(restored, remote)
        XCTAssertNotEqual(FileWorkspaceStore.selectionKey(for: local.selection), key)
    }

    func testLocalFamilyProjectAndPrimaryAttachmentSurviveReopenAndCleanup() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileWorkspaceStore(rootURL: directory)
        let files = AttachmentStore(rootURL: directory, maximumCacheBytes: 0)
        let service = TaskWorkspaceService(persistence: persistence, taskCodec: ObsidianTaskCodec(), attachmentStore: files)
        let workspace = try await service.createLocalWorkspace()
        let selection = workspace.selection
        XCTAssertEqual(workspace.configuration.schemaVersion, 2)
        _ = try await service.addProject(selection: selection, slug: "home", title: "Home", body: "# Plans\n\nKeep **notes**.")
        let bytes = Data([0, 255, 128, 42])
        let draft = try await files.stage(data: bytes, filename: "receipt.bin", selection: selection)
        let parent = try await service.addTask(selection: selection, name: "Local family", projectSlugs: ["home"], tags: ["focus"],
                                               attachments: [draft], subtaskNames: ["Child"])
        let saved = try await service.loadWorkspace(selection: selection)
        let project = try XCTUnwrap(saved.projects.first?.project)
        _ = try await service.updateProject(selection: selection, expectedProject: project, name: "Household", body: project.body)
        var update = TaskUpdate(task: parent)
        update.name = "Updated family"
        let edited = try await service.editTask(selection: selection, id: parent.id, expectedTask: parent, update: update)
        try await files.discard(drafts: [draft], selection: selection, persistence: persistence)
        try await files.evict(selection: selection, workspace: saved)

        let reopenedService = TaskWorkspaceService(persistence: FileWorkspaceStore(rootURL: directory), taskCodec: ObsidianTaskCodec())
        let reopened = try await reopenedService.createLocalWorkspace()
        XCTAssertEqual(reopened.tasks.first(where: { $0.task.id == parent.id })?.task, edited)
        let child = try XCTUnwrap(reopened.tasks.first(where: { $0.task.parentID == parent.id })?.task)
        XCTAssertEqual(child.name, "Child")
        XCTAssertEqual(child.projectSlugs, ["home"])
        XCTAssertEqual(reopened.projects.first?.project.name, "Household")
        XCTAssertEqual(reopened.projects.first?.project.body, project.body)
        XCTAssertTrue(reopened.pendingChanges.isEmpty)
        XCTAssertTrue(reopened.conflicts.isEmpty)
        XCTAssertEqual(reopened.localAttachmentFiles[draft.path], draft.localFile)
        let retained = try await AttachmentStore(rootURL: directory).read(draft.localFile, selection: selection)
        XCTAssertEqual(retained, bytes)
        XCTAssertEqual(AttachmentLinks.references(body: edited.body, taskPath: edited.relativePath).map(\.path), [draft.path])

        try await reopenedService.deleteTask(selection: selection, id: child.id, expectedTask: child)
        try await reopenedService.deleteTask(selection: selection, id: edited.id, expectedTask: edited)
        let deleted = try await reopenedService.loadWorkspace(selection: selection)
        XCTAssertTrue(deleted.tasks.isEmpty)
        XCTAssertTrue(deleted.pendingChanges.isEmpty)
        let stillRetained = try await files.read(draft.localFile, selection: selection)
        XCTAssertEqual(stillRetained, bytes, "Removing tasks or links must not delete a potentially shared attachment")
    }

    func testSelectingDifferentWorkspacesNeverCopiesLocalTasksIntoRemoteOutbox() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileWorkspaceStore(rootURL: directory)
        let service = TaskWorkspaceService(persistence: persistence, taskCodec: ObsidianTaskCodec())
        let local = try await service.createLocalWorkspace()
        _ = try await service.addTask(selection: local.selection, name: "Private local task")
        let remoteSelection = try WorkspaceSelection(owner: "example", name: "vault", branch: "main", storePath: "")
        try await persistence.save(WorkspaceState(selection: remoteSelection, configuration: local.configuration, tasks: [],
                                                  baseHeadCommitSHA: "head", baseRootTreeSHA: "tree", pendingChanges: [], conflicts: []), expectedRevision: nil)
        _ = try await service.addTask(selection: remoteSelection, name: "GitHub task")
        let remote = try await service.loadWorkspace(selection: remoteSelection)
        XCTAssertEqual(remote.tasks.map(\.task.name), ["GitHub task"])
        XCTAssertEqual(remote.pendingChanges.count, 1)
        XCTAssertFalse(remote.pendingChanges.contains { $0.content?.contains("Private local task") == true })
        let restored = try await service.createLocalWorkspace()
        XCTAssertEqual(restored.tasks.map(\.task.name), ["Private local task"])
        XCTAssertTrue(restored.pendingChanges.isEmpty)

        let other = try await service.createLocalWorkspace(selection: .local(id: UUID()))
        XCTAssertTrue(other.tasks.isEmpty)
        XCTAssertNotEqual(FileWorkspaceStore.selectionKey(for: other.selection), FileWorkspaceStore.selectionKey(for: restored.selection))
    }

    func testLocalSelectionIsRejectedBeforeAnyGitHubRequest() async throws {
        let transport = RecordingTransport()
        let client = GitHubAPIClient(accessToken: "unused", transport: transport)
        do {
            _ = try await client.fetchSnapshot(selection: .onDevice)
            XCTFail("A local workspace must never be used as a GitHub repository")
        } catch let error as OTodoError {
            guard case .validation(field: "workspace", message: _) = error else { throw error }
        }
        let requests = await transport.requestCount
        XCTAssertEqual(requests, 0)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("local-workspace-" + UUID().uuidString)
    }
}

private actor RecordingTransport: HTTPTransport {
    private(set) var requestCount = 0
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requestCount += 1
        throw OTodoError.transport(statusCode: nil, message: "Unexpected network request")
    }
}
