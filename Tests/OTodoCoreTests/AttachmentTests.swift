import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OTodoCore

final class AttachmentTests: XCTestCase, @unchecked Sendable {
    func testSharedRustMarkdownFixtures() throws {
        struct Fixtures: Decodable {
            struct Case: Decodable { let name: String; let task_path: String; let body: String; let paths: [String]; let unlink_path: String; let unlinked: String; let store_prefix: String? }
            struct Filename: Decodable { let input: String; let output: String }
            let cases: [Case]; let filenames: [Filename]
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "attachments", withExtension: "json"))
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
        for fixture in fixtures.cases {
            XCTAssertEqual(AttachmentLinks.references(body: fixture.body, taskPath: fixture.task_path, storePrefix: fixture.store_prefix ?? "").map(\.path), fixture.paths, fixture.name)
            XCTAssertEqual(AttachmentLinks.unlink(body: fixture.body, taskPath: fixture.task_path, path: fixture.unlink_path, storePrefix: fixture.store_prefix ?? ""), fixture.unlinked, fixture.name)
        }
        for fixture in fixtures.filenames { XCTAssertEqual(AttachmentLinks.sanitizeFilename(fixture.input), fixture.output) }
    }

    func testGitSHAAndNestedRebasePreserveSurroundingBytes() throws {
        XCTAssertEqual(GitBlobSHA.hexDigest(Data()), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        XCTAssertEqual(GitBlobSHA.hexDigest(Data("hello".utf8)), "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0")
        let original = "prefix\r\n[Report](../../Attachments/café.pdf)\r\nsuffix"
        let moved = AttachmentLinks.rebase(body: original, from: "Tasks/nested/task.md", to: "Work/2026/nested/task.md")
        XCTAssertEqual(moved, "prefix\r\n[Report](../../../Attachments/caf%C3%A9.pdf)\r\nsuffix")
        XCTAssertEqual(AttachmentLinks.references(body: moved, taskPath: "Work/2026/nested/task.md").first?.path, "Attachments/café.pdf")
        let withFragment = "[Report](<../../Attachments/caf%C3%A9.pdf#page=2> \"Title\") [[Attachments/café.pdf#page=3|Wiki]]"
        XCTAssertEqual(AttachmentLinks.rebase(body: withFragment, from: "Tasks/nested/task.md", to: "Tasks/task.md"),
            "[Report](<../Attachments/caf%C3%A9.pdf#page=2> \"Title\") [[Attachments/café.pdf#page=3|Wiki]]")
    }

    func testAttachmentsSaveAndCleanupAreSafeInBothStoreSchemas() async throws {
        for version in [1, 2] {
            let f = try await Fixture(version: version)
            defer { f.cleanup() }
            let draft = try await f.bytes.stage(data: Data([0, 255, 1, 128]), filename: "café photo.png", selection: f.selection)
            let task = try await f.service.addTask(selection: f.selection, name: "With receipt", attachments: [draft])
            let saved = try await f.service.loadWorkspace(selection: f.selection)
            XCTAssertEqual(saved.configuration.schemaVersion, version)
            XCTAssertEqual(saved.pendingChanges.count, 2)
            XCTAssertEqual(AttachmentLinks.references(body: task.body, taskPath: task.relativePath).map(\.path), [draft.path])
            XCTAssertEqual(saved.pendingChanges.first(where: { $0.payload.binaryFile != nil })?.payload, .binaryFile(draft.localFile))
            try await f.bytes.discard(drafts: [draft], selection: f.selection, persistence: f.persistence)
            let retained = try await f.bytes.read(draft.localFile, selection: f.selection)
            XCTAssertEqual(retained, Data([0, 255, 1, 128]))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.workspaceURL)) as? [String: Any])
            XCTAssertEqual(json["version"] as? Int, 3)
            let orphan = try await f.bytes.stage(data: Data([2]), filename: "orphan.pdf", selection: f.selection)
            let orphanURL = try await f.bytes.localURL(orphan.localFile, selection: f.selection)
            try await f.bytes.discard(drafts: [orphan], selection: f.selection, persistence: f.persistence)
            XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
            try await f.service.deleteTask(selection: f.selection, id: task.id, expectedTask: task)
            let afterDeletion = try await f.bytes.read(draft.localFile, selection: f.selection)
            XCTAssertEqual(afterDeletion, retained)
        }
    }

    func testTaskUpdateOverloadAddsAndRemovesAttachmentsInOneSave() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let old = try await f.bytes.stage(data: Data([1]), filename: "old.pdf", selection: f.selection)
        let task = try await f.service.addTask(selection: f.selection, name: "Original", attachments: [old])
        let before = try await f.service.loadWorkspace(selection: f.selection)
        let added = try await f.bytes.stage(data: Data([2, 3]), filename: "replacement.pdf", selection: f.selection)
        var update = TaskUpdate(task: task)
        update.name = "Updated from the editor"
        // This is the exact TaskUpdate-based overload invoked by AppModel's editor save.
        let edited = try await f.service.editTask(selection: f.selection, id: task.id, expectedTask: task,
            update: update, attachments: [added], removingAttachmentPaths: [old.path])
        let after = try await f.service.loadWorkspace(selection: f.selection)
        XCTAssertEqual(after.revision, before.revision + 1)
        XCTAssertEqual(edited.name, update.name)
        XCTAssertEqual(AttachmentLinks.references(body: edited.body, taskPath: edited.relativePath).map(\.path), [added.path])
        XCTAssertEqual(after.tasks.first?.task, edited)
        XCTAssertEqual(after.pendingChanges.first { $0.path == "todos/" + added.path }?.payload, .binaryFile(added.localFile))
        XCTAssertEqual(after.pendingChanges.first { $0.path == "todos/" + task.relativePath }?.id,
            before.pendingChanges.first { $0.path == "todos/" + task.relativePath }?.id)
        let retained = try await f.bytes.read(old.localFile, selection: f.selection)
        XCTAssertEqual(retained, Data([1]))
    }

    func testBytesSurviveContainerRelocationAndFailedTaskSave() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let draft = try await f.bytes.stage(data: Data([255, 0, 65]), filename: "receipt.pdf", selection: f.selection)
        do { _ = try await f.service.addTask(selection: f.selection, name: "", attachments: [draft]); XCTFail("Expected validation") } catch {}
        let initial = try await f.service.loadWorkspace(selection: f.selection)
        XCTAssertTrue(initial.tasks.isEmpty)
        _ = try await f.service.addTask(selection: f.selection, name: "Saved", attachments: [draft])
        let moved = f.root.appendingPathExtension("relocated")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: f.root, to: moved)
        let store = AttachmentStore(rootURL: moved)
        let bytes = try await store.read(draft.localFile, selection: f.selection)
        XCTAssertEqual(bytes, Data([255, 0, 65]))
        let restored = try await FileWorkspaceStore(rootURL: moved).load(selection: f.selection)
        XCTAssertEqual(restored?.pendingChanges.count, 2)
        XCTAssertFalse(draft.localFile.localReference.hasPrefix("/"))
    }

    func testGenuineHistoricalOutboxesMigrateToExplicitPayloads() async throws {
        for version in [1, 2] {
            let f = try await Fixture()
            defer { f.cleanup() }
            let id = UUID().uuidString
            let raw = "---\nname: Preserved\nstate: open\nprojects: []\ntags: []\n---\nexact\r\nbody"
            let config = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.configuration))
            let selection = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.selection))
            let old: [String: Any] = ["version": version, "workspace": [
                "selection": selection, "configuration": config, "tasks": [], "knownProjectSlugs": [],
                "baseHeadCommitSHA": "h1", "baseRootTreeSHA": "t1", "revision": 9,
                "pendingChanges": [["id": id, "path": "todos/Tasks/a.md", "baseBlobSHA": "base", "content": raw, "createdAt": 123],
                                   ["id": UUID().uuidString, "path": "todos/Tasks/b.md", "baseBlobSHA": "base2", "createdAt": 456]],
                "conflicts": [["path": "todos/Tasks/a.md", "baseBlobSHA": "base", "remoteBlobSHA": "remote", "localContent": raw, "remoteContent": "remote raw\r\n"]]]]
            try JSONSerialization.data(withJSONObject: old).write(to: f.workspaceURL)
            let loadedValue = try await f.persistence.load(selection: f.selection)
            let loaded = try XCTUnwrap(loadedValue)
            XCTAssertEqual(loaded.pendingChanges[0].id.uuidString, id)
            XCTAssertEqual(loaded.pendingChanges[0].payload, .text(raw))
            XCTAssertEqual(loaded.pendingChanges[1].payload, .deletion)
            XCTAssertEqual(loaded.pendingChanges[1].createdAt, Date(timeIntervalSinceReferenceDate: 456))
            XCTAssertEqual(loaded.conflicts[0].localPayload, .text(raw))
            XCTAssertEqual(loaded.conflicts[0].remotePayload, .text("remote raw\r\n"))
            _ = try await f.service.addTask(selection: f.selection, name: "Migrate on save")
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.workspaceURL)) as? [String: Any])
            XCTAssertEqual(envelope["version"] as? Int, 3)
            let workspace = try XCTUnwrap(envelope["workspace"] as? [String: Any])
            let pending = try XCTUnwrap(workspace["pendingChanges"] as? [[String: Any]])
            XCTAssertNotNil(pending[0]["payload"])
            XCTAssertNil(pending[0]["content"])
            // Historical readers gate on envelope versions before decoding content:nil deletion semantics.
            XCTAssertFalse([1, 2].contains(try XCTUnwrap(envelope["version"] as? Int)))
        }
    }

    func testBinaryPublicationIsOneCommitAndConfirmationRetryRetainsOfflineBytes() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let draft = try await f.bytes.stage(data: Data([0, 255, 100]), filename: "receipt.pdf", selection: f.selection)
        let task = try await f.service.addTask(selection: f.selection, name: "Receipt", attachments: [draft])
        await f.remote.failNextConfirmation()
        do { _ = try await f.engine.sync(selection: f.selection); XCTFail("Confirmation should fail") } catch {}
        let pending = try await f.service.loadWorkspace(selection: f.selection)
        XCTAssertEqual(pending.pendingChanges.count, 2)
        let commits = await f.remote.committed()
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(Set(commits[0].map(\.path)), ["todos/" + draft.path, "todos/" + task.relativePath])
        XCTAssertEqual(commits[0].first(where: { $0.binaryContent != nil })?.binaryContent, Data([0, 255, 100]))
        _ = try await f.engine.sync(selection: f.selection)
        let confirmed = try await f.service.loadWorkspace(selection: f.selection)
        XCTAssertTrue(confirmed.pendingChanges.isEmpty)
        try await f.bytes.discard(drafts: [draft], selection: f.selection, persistence: f.persistence)
        let cached = try await f.bytes.cachedFile(path: "todos/" + draft.path, selection: f.selection, expectedSHA: draft.localFile.blobSHA)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(cached).url), Data([0, 255, 100]))
        XCTAssertEqual(confirmed.attachments.first?.blobSHA, draft.localFile.blobSHA)
        let finalCommits = await f.remote.committed()
        XCTAssertEqual(finalCommits.count, 1)
    }

    func testCollisionWithholdsTaskChildAndUploadThenDiscardUnlinks() async throws {
        let f = try await Fixture(version: 2)
        defer { f.cleanup() }
        let draft = try await f.bytes.stage(data: Data([0, 1]), filename: "a.pdf", selection: f.selection)
        let parent = try await f.service.addTask(selection: f.selection, name: "Parent", attachments: [draft])
        _ = try await f.service.addTask(selection: f.selection, name: "Child", parentID: parent.id)
        await f.remote.putAttachment(path: "todos/" + draft.path, data: Data([9, 8]))
        let report = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(report.pushedCount, 0)
        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertNotNil(report.conflicts[0].localPayload.binaryFile)
        let commits = await f.remote.committed()
        XCTAssertTrue(commits.isEmpty)
        do { _ = try await f.service.keepLocalConflict(selection: f.selection, path: "todos/" + draft.path); XCTFail("Must never overwrite collision") } catch {}
        let discarded = try await f.service.useRemoteConflict(selection: f.selection, path: "todos/" + draft.path)
        XCTAssertTrue(discarded.conflicts.isEmpty)
        XCTAssertFalse(discarded.pendingChanges.contains(where: { $0.payload.binaryFile != nil }))
        XCTAssertTrue(discarded.tasks.allSatisfy { AttachmentLinks.references(body: $0.task.body, taskPath: $0.task.relativePath).isEmpty })
        _ = try await f.engine.sync(selection: f.selection)
        let after = await f.remote.committed()
        XCTAssertEqual(after.count, 1)
        XCTAssertTrue(after[0].allSatisfy { $0.binaryContent == nil })
    }

    func testRemoteSchemaActivationRetainsBlockedLegacyParentAttachmentWork() async throws {
        let f = try await Fixture(version: 1)
        defer { f.cleanup() }
        let draft = try await f.bytes.stage(data: Data([42]), filename: "legacy.pdf", selection: f.selection)
        let task = try await f.service.addTask(selection: f.selection, name: "Legacy", attachments: [draft])
        let state = try await f.service.loadWorkspace(selection: f.selection)
        let path = "todos/" + task.relativePath
        var modified = task
        modified.extraProperties.append(YAMLProperty(name: "parent", value: .null))
        let raw = try ObsidianTaskCodec().serializeTask(modified, configuration: f.configuration)
        let changes = try state.pendingChanges.map { change in
            change.path == path ? try PendingChange(id: change.id, path: change.path, baseBlobSHA: change.baseBlobSHA, content: raw, createdAt: change.createdAt) : change
        }
        let changed = try WorkspaceState(selection: f.selection, configuration: f.configuration,
            tasks: [TaskDocument(task: modified, content: raw, blobSHA: nil)], baseHeadCommitSHA: state.baseHeadCommitSHA,
            baseRootTreeSHA: state.baseRootTreeSHA, pendingChanges: changes, conflicts: [], revision: state.revision + 1)
        try await f.persistence.save(changed, expectedRevision: state.revision)
        await f.remote.setSchema(2)
        _ = try await f.engine.sync(selection: f.selection)
        let retained = try await f.service.loadWorkspace(selection: f.selection)
        XCTAssertEqual(retained.configuration.schemaVersion, 1)
        XCTAssertEqual(retained.pendingChanges, changes)
        XCTAssertEqual(retained.tasks[0].content, raw)
        XCTAssertTrue(retained.relationshipBlocks.contains { $0.code == "unsupported_schema" })
        let bytes = try await f.bytes.read(draft.localFile, selection: f.selection)
        XCTAssertEqual(bytes, Data([42]))
        let commits = await f.remote.committed()
        XCTAssertTrue(commits.isEmpty)
    }

    func testPinsAndPendingImportsDoNotConsumeTheEvictableBudget() async throws {
        let f = try await Fixture(cacheBudget: 3)
        defer { f.cleanup() }
        let pinned = try await f.bytes.stage(data: Data(repeating: 1, count: 6), filename: "pinned.pdf", selection: f.selection)
        _ = try await f.service.addTask(selection: f.selection, name: "Pinned", attachments: [pinned])
        _ = try await f.engine.sync(selection: f.selection)
        try await f.bytes.setPinned(path: "todos/" + pinned.path, selection: f.selection, pinned: true)
        let pending = try await f.bytes.stage(data: Data(repeating: 2, count: 5), filename: "pending.pdf", selection: f.selection)
        _ = try await f.service.addTask(selection: f.selection, name: "Pending", attachments: [pending])
        try await f.bytes.retainVerified(pending.localFile, path: "todos/" + pending.path, selection: f.selection)
        let workspace = try await f.service.loadWorkspace(selection: f.selection)

        let oldPath = "todos/Attachments/old.pdf", newPath = "todos/Attachments/new.pdf"
        await f.remote.putAttachment(path: oldPath, data: Data([3, 3]))
        await f.remote.putAttachment(path: newPath, data: Data([4, 4]))
        let snapshot = try await f.remote.fetchSnapshot(selection: f.selection)
        let oldMetadata = try XCTUnwrap(snapshot.attachments.first { $0.path == oldPath })
        let newMetadata = try XCTUnwrap(snapshot.attachments.first { $0.path == newPath })
        let old = try await f.bytes.download(attachment: oldMetadata, selection: f.selection, gitHub: f.remote)
        try await f.bytes.evict(selection: f.selection, workspace: workspace)
        XCTAssertEqual(try Data(contentsOf: old.url), Data([3, 3]))

        let new = try await f.bytes.download(attachment: newMetadata, selection: f.selection, gitHub: f.remote)
        try await f.bytes.evict(selection: f.selection, workspace: workspace)
        XCTAssertEqual(try Data(contentsOf: new.url), Data([4, 4]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.url.path))
        // The app opens and evicts before offering Keep offline; the downloaded entry must still exist.
        try await f.bytes.setPinned(path: newPath, selection: f.selection, pinned: true)
        let kept = try await f.bytes.cachedFile(path: newPath, selection: f.selection)
        XCTAssertEqual(kept?.isPinned, true)
        let protected = try await f.bytes.cachedFile(path: "todos/" + pending.path, selection: f.selection)
        XCTAssertNotNil(protected)
        let pinnedData = try await f.bytes.read(pinned.localFile, selection: f.selection)
        XCTAssertEqual(pinnedData.count, 6)
    }

    func testPinnedReplacementFailureRetainsOlderVersionAndEvictionProtectsPendingAndPins() async throws {
        let f = try await Fixture(cacheBudget: 1)
        defer { f.cleanup() }
        let draft = try await f.bytes.stage(data: Data([1, 2, 3]), filename: "pin.pdf", selection: f.selection)
        _ = try await f.service.addTask(selection: f.selection, name: "Pinned", attachments: [draft])
        _ = try await f.engine.sync(selection: f.selection)
        let path = "todos/" + draft.path
        try await f.bytes.setPinned(path: path, selection: f.selection, pinned: true)
        await f.remote.putAttachment(path: path, data: Data([4, 5, 6]))
        let snapshot = try await f.remote.fetchSnapshot(selection: f.selection)
        await f.remote.setDownloadFailure(true)
        let failures = await f.bytes.refreshPinned(attachments: snapshot.attachments, selection: f.selection, gitHub: f.remote)
        XCTAssertNotNil(failures[path])
        let old = try await f.bytes.cachedFile(path: path, selection: f.selection, expectedSHA: snapshot.attachments[0].blobSHA)
        XCTAssertEqual(old?.isOlderVersion, true)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(old).url), Data([1, 2, 3]))
        let state = try await f.service.loadWorkspace(selection: f.selection)
        try await f.bytes.evict(selection: f.selection, workspace: state)
        let pinned = try await f.bytes.cachedFile(path: path, selection: f.selection)
        XCTAssertNotNil(pinned)
        await f.remote.setDownloadFailure(false)
        let refreshed = await f.bytes.refreshPinned(attachments: snapshot.attachments, selection: f.selection, gitHub: f.remote)
        XCTAssertTrue(refreshed.isEmpty)
        let new = try await f.bytes.cachedFile(path: path, selection: f.selection, expectedSHA: snapshot.attachments[0].blobSHA)
        XCTAssertEqual(new?.isOlderVersion, false)
        XCTAssertEqual(new?.isPinned, true)
        try await f.bytes.setPinned(path: path, selection: f.selection, pinned: false)
        try await f.bytes.evict(selection: f.selection, workspace: state)
        let evicted = try await f.bytes.cachedFile(path: path, selection: f.selection)
        XCTAssertNil(evicted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(new).url.path))
    }

    func testInclusive20MiBLimitAndUnsafePaths() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let data = Data(repeating: 0x7f, count: AttachmentLinks.maximumBytes)
        let draft = try await f.bytes.stage(data: data, filename: "limit.bin", selection: f.selection)
        XCTAssertEqual(draft.byteSize, 20 * 1_024 * 1_024)
        do { _ = try await f.bytes.stage(data: data + Data([0]), filename: "too-large.bin", selection: f.selection); XCTFail("Must reject over limit") } catch {}
        let source = f.root.appendingPathComponent("source")
        try Data([1]).write(to: source)
        let symlink = f.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        do { _ = try await f.bytes.stage(sourceURL: symlink, selection: f.selection); XCTFail("Must reject symlink") } catch {}
        XCTAssertThrowsError(try BinaryFileReference(localReference: "bytes/../outside", byteSize: 1, blobSHA: draft.localFile.blobSHA))
        XCTAssertThrowsError(try AttachmentLinks.validate(path: "Attachments/../Tasks/x.md"))
    }

    func testStaleHeadRetryPublishesBinaryAndTaskTogether() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let draft = try await f.bytes.stage(data: Data([8, 0, 255]), filename: "retry.pdf", selection: f.selection)
        _ = try await f.service.addTask(selection: f.selection, name: "Retry", attachments: [draft])
        await f.remote.rejectNextHeadAsStale()
        let report = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(report.pushedCount, 2)
        let attempts = await f.remote.committed()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0], attempts[1])
        let current = try await f.service.loadWorkspace(selection: f.selection)
        XCTAssertTrue(current.pendingChanges.isEmpty)
        let cached = try await f.bytes.cachedFile(path: "todos/" + draft.path, selection: f.selection)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(cached).url), Data([8, 0, 255]))
    }

    func testTaskConflictWithholdsItsNewAttachmentUpload() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let draft = try await f.bytes.stage(data: Data([3]), filename: "withheld.pdf", selection: f.selection)
        let task = try await f.service.addTask(selection: f.selection, name: "Local task", attachments: [draft])
        var changed = task
        changed.body = "Remote version"
        await f.remote.putText(path: "todos/" + task.relativePath, text: try ObsidianTaskCodec().serializeTask(changed, configuration: f.configuration))
        let report = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertEqual(report.conflicts[0].path, "todos/" + task.relativePath)
        let attempts = await f.remote.committed()
        XCTAssertTrue(attempts.isEmpty)
        let bytes = try await f.bytes.read(draft.localFile, selection: f.selection)
        XCTAssertEqual(bytes, Data([3]))
    }

    func testOverlappingRecordDirectoryDisablesAttachmentsButAllowsOrdinaryTodos() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let overlap = try StoreConfiguration(schemaVersion: 1, tasksDirectory: "Attachments", projectsDirectory: "Projects",
            obsidianLinkPrefix: "", defaultState: "open", states: f.configuration.states)
        let workspace = try WorkspaceState(selection: f.selection, configuration: overlap, tasks: [],
            baseHeadCommitSHA: "h1", baseRootTreeSHA: "t1", pendingChanges: [], conflicts: [], revision: 1)
        try await f.persistence.save(workspace, expectedRevision: 0)
        let task = try await f.service.addTask(selection: f.selection, name: "Ordinary todo")
        XCTAssertTrue(task.relativePath.hasPrefix("Attachments/"))
        let draft = try await f.bytes.stage(data: Data([1]), filename: "disabled.pdf", selection: f.selection)
        do { _ = try await f.service.addTask(selection: f.selection, name: "Attachment", attachments: [draft]); XCTFail("Overlap must disable imports") } catch {}
        let saved = try await f.service.loadWorkspace(selection: f.selection)
        XCTAssertEqual(saved.tasks.count, 1)
    }

    func testOrphanedBinaryConflictStillWithholdsDependentTask() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let draft = try await f.bytes.stage(data: Data([1]), filename: "orphan.pdf", selection: f.selection)
        _ = try await f.service.addTask(selection: f.selection, name: "Has orphan conflict", attachments: [draft])
        let state = try await f.service.loadWorkspace(selection: f.selection)
        let conflict = try SyncConflict(path: "todos/" + draft.path, baseBlobSHA: nil, remoteBlobSHA: nil,
            localPayload: .binaryFile(draft.localFile), remotePayload: .deletion)
        let orphaned = try WorkspaceState(selection: state.selection, configuration: state.configuration, tasks: state.tasks,
            baseHeadCommitSHA: state.baseHeadCommitSHA, baseRootTreeSHA: state.baseRootTreeSHA,
            pendingChanges: state.pendingChanges.filter { $0.payload.binaryFile == nil }, conflicts: [conflict], revision: state.revision + 1)
        try await f.persistence.save(orphaned, expectedRevision: state.revision)
        let report = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(report.pushedCount, 0)
        let commits = await f.remote.committed()
        XCTAssertTrue(commits.isEmpty)
        let retained = try await f.bytes.read(draft.localFile, selection: f.selection)
        XCTAssertEqual(retained, Data([1]))
    }

    func testDiscardCollisionUpdatesDependentTaskConflictBeforeKeepLocal() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let draft = try await f.bytes.stage(data: Data([1]), filename: "both.pdf", selection: f.selection)
        let task = try await f.service.addTask(selection: f.selection, name: "Local", attachments: [draft])
        var remoteTask = task
        remoteTask.name = "Remote task"
        remoteTask.body = "Remote body"
        await f.remote.putText(path: "todos/" + task.relativePath, text: try ObsidianTaskCodec().serializeTask(remoteTask, configuration: f.configuration))
        await f.remote.putAttachment(path: "todos/" + draft.path, data: Data([2]))
        let conflicts = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(conflicts.conflicts.count, 2)
        _ = try await f.service.useRemoteConflict(selection: f.selection, path: "todos/" + draft.path)
        let resolved = try await f.service.keepLocalConflict(selection: f.selection, path: "todos/" + task.relativePath)
        XCTAssertTrue(AttachmentLinks.references(body: resolved.tasks[0].task.body, taskPath: task.relativePath).isEmpty)
        _ = try await f.engine.sync(selection: f.selection)
        let committed = await f.remote.committed()
        XCTAssertFalse(committed.flatMap { $0 }.contains { $0.content?.contains(draft.path) == true })
    }

    func testDiscardImportRewritesRetiredTaskConflictBodyWithoutChangingFrontmatter() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let draft = try await f.bytes.stage(data: Data([1]), filename: "retired.pdf", selection: f.selection)
        let task = try await f.service.addTask(selection: f.selection, name: "Retired", attachments: [draft])
        let state = try await f.service.loadWorkspace(selection: f.selection)
        let document = try XCTUnwrap(state.tasks.first)
        let custom = "attachments: \"[[\(draft.path)]]\"\n"
        let raw = "---\n" + custom + String(document.content.dropFirst(4))
        let moved = try StoreConfiguration(schemaVersion: 1, tasksDirectory: "Work", projectsDirectory: "Projects",
            obsidianLinkPrefix: "", defaultState: "open", states: state.configuration.states)
        let taskPath = "todos/" + task.relativePath, binaryPath = "todos/" + draft.path
        let pending = try state.pendingChanges.map { operation in
            operation.path == taskPath ? try PendingChange(id: operation.id, path: operation.path, baseBlobSHA: "old-base", content: raw, createdAt: operation.createdAt) : operation
        }
        let conflicts = [try SyncConflict(path: taskPath, baseBlobSHA: "old-base", remoteBlobSHA: nil, localContent: raw, remoteContent: nil),
            try SyncConflict(path: binaryPath, baseBlobSHA: nil, remoteBlobSHA: "collision", localPayload: .binaryFile(draft.localFile),
                remotePayload: .remoteBinary(AttachmentMetadata(path: binaryPath, blobSHA: "collision", byteSize: 1)))]
        let retired = try WorkspaceState(selection: state.selection, configuration: moved, tasks: [],
            baseHeadCommitSHA: state.baseHeadCommitSHA, baseRootTreeSHA: state.baseRootTreeSHA,
            pendingChanges: pending, conflicts: conflicts, revision: state.revision + 1)
        try await f.persistence.save(retired, expectedRevision: state.revision)
        let discarded = try await f.service.useRemoteConflict(selection: f.selection, path: binaryPath)
        let remaining = try XCTUnwrap(discarded.pendingChanges.first)
        XCTAssertEqual(remaining.id, pending.first { $0.path == taskPath }?.id)
        XCTAssertEqual(remaining.createdAt, pending.first { $0.path == taskPath }?.createdAt)
        XCTAssertTrue(try XCTUnwrap(remaining.content).hasPrefix("---\n" + custom))
        let restored = try await f.service.keepLocalConflict(selection: f.selection, path: taskPath)
        XCTAssertEqual(restored.tasks.first?.task.relativePath, "Work/" + task.id.rawValue + ".md")
        XCTAssertTrue(AttachmentLinks.references(body: try XCTUnwrap(restored.tasks.first).task.body, taskPath: "Work/" + task.id.rawValue + ".md").isEmpty)
        XCTAssertEqual(restored.tasks.first?.task.extraProperties.first { $0.name == "attachments" }?.value, .string("[[\(draft.path)]]"))
    }

    func testDirectoryAndAncestorSymlinkCollisionsPublishNothing() async throws {
        for ancestor in [false, true] {
            let f = try await Fixture()
            defer { f.cleanup() }
            let draft = try await f.bytes.stage(data: Data([1]), filename: "collision.pdf", selection: f.selection)
            _ = try await f.service.addTask(selection: f.selection, name: "Collision", attachments: [draft])
            let path = ancestor ? "todos/Attachments" : "todos/" + draft.path
            await f.remote.putMetadata(try AttachmentMetadata(path: path, blobSHA: "occupied", byteSize: 0, isSymlink: ancestor, isDirectory: !ancestor))
            let report = try await f.engine.sync(selection: f.selection)
            XCTAssertEqual(report.pushedCount, 0)
            XCTAssertEqual(report.conflicts.count, 1)
            let commits = await f.remote.committed()
            XCTAssertTrue(commits.isEmpty)
        }
    }

    func testSchemaActivationPreservesAndPublishesOrdinaryAttachmentImports() async throws {
        let f = try await Fixture(version: 1)
        defer { f.cleanup() }
        let draft = try await f.bytes.stage(data: Data([99]), filename: "upgrade.pdf", selection: f.selection)
        _ = try await f.service.addTask(selection: f.selection, name: "Activate", attachments: [draft])
        await f.remote.setSchema(2)
        _ = try await f.engine.sync(selection: f.selection)
        let upgraded = try await f.service.loadWorkspace(selection: f.selection)
        XCTAssertEqual(upgraded.configuration.schemaVersion, 2)
        XCTAssertTrue(upgraded.pendingChanges.isEmpty)
        let cached = try await f.bytes.cachedFile(path: "todos/" + draft.path, selection: f.selection)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(cached).url), Data([99]))
    }

    func testConcurrentSaveAndCancelEitherRetainsDurableBytesOrPreventsPublication() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        for index in 0..<10 {
            let draft = try await f.bytes.stage(data: Data([UInt8(index)]), filename: "race.pdf", selection: f.selection)
            let service = f.service, selection = f.selection, bytes = f.bytes, persistence = f.persistence
            async let saved: TodoTask? = try? service.addTask(selection: selection, name: "Race \(index)", attachments: [draft])
            async let cancelled: Void = bytes.discard(drafts: [draft], selection: selection, persistence: persistence)
            let (task, _) = try await (saved, cancelled)
            if task != nil {
                let retained = try await f.bytes.read(draft.localFile, selection: selection)
                XCTAssertEqual(retained, Data([UInt8(index)]))
            }
        }
        let workspace = try await f.service.loadWorkspace(selection: f.selection)
        for operation in workspace.pendingChanges {
            if let file = operation.payload.binaryFile {
                let data = try await f.bytes.read(file, selection: f.selection)
                XCTAssertEqual(data.count, file.byteSize)
            }
        }
    }

    func testGitHubSnapshotCataloguesWithoutDownloadingBinaryAndCommitUsesBase64() async throws {
        let config = Data(AttachmentRemote.configuration(1).utf8)
        let binary = Data([0, 255, 42])
        let sha = GitBlobSHA.hexDigest(binary)
        let transport = try AttachmentScriptTransport(objects: [
            ["object": ["sha": "head"]], ["sha": "head", "tree": ["sha": "tree"]],
            ["sha": "tree", "truncated": false, "tree": [
                ["path": ".todo/config.toml", "mode": "100644", "type": "blob", "sha": "config", "size": config.count],
                ["path": "Attachments", "mode": "040000", "type": "tree", "sha": "directory"],
                ["path": "Attachments/photo.png", "mode": "100644", "type": "blob", "sha": sha, "size": binary.count],
                ["path": "Attachments/unsafe.pdf", "mode": "120000", "type": "blob", "sha": "symlink", "size": 10]]],
            ["content": config.base64EncodedString(), "encoding": "base64"],
            ["sha": sha], ["sha": "new-tree"], ["sha": "commit"]])
        let client = GitHubAPIClient(accessToken: "token", transport: transport)
        let selection = try RepositorySelection(owner: "owner", name: "repo", branch: "main", storePath: "")
        let snapshot = try await client.fetchSnapshot(selection: selection)
        XCTAssertEqual(snapshot.files.count, 1)
        XCTAssertEqual(snapshot.attachments.count, 3)
        XCTAssertEqual(snapshot.attachments.first { $0.path == "Attachments/unsafe.pdf" }?.isSymlink, true)
        let initial = await transport.requests()
        XCTAssertEqual(initial.count, 4)
        XCTAssertEqual(initial.filter { $0.url?.path.contains("/git/blobs/") == true }.count, 1)
        _ = try await client.commit(selection: selection, changes: [RemoteChange(path: "Attachments/new.png", content: nil, binaryContent: binary)], against: snapshot, message: "Attachment")
        let requests = await transport.requests()
        let upload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[4].httpBody)) as? [String: String])
        XCTAssertEqual(upload["encoding"], "base64")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(upload["content"])), binary)
    }

    func testAttachmentDownloadRequests32MiBResponseAndVerifiesBytes() async throws {
        let data = Data([0, 255, 128])
        let sha = GitBlobSHA.hexDigest(data)
        let transport = AttachmentHTTPTransport(data: data)
        let client = GitHubAPIClient(accessToken: "token", transport: transport)
        let selection = try RepositorySelection(owner: "owner", name: "repo", branch: "main", storePath: "todos")
        let metadata = try AttachmentMetadata(path: "todos/Attachments/test.bin", blobSHA: sha, byteSize: data.count)
        let downloaded = try await client.fetchAttachment(selection: selection, attachment: metadata)
        XCTAssertEqual(downloaded, data)
        let limit = await transport.recordedLimit()
        XCTAssertEqual(limit, 32 * 1_024 * 1_024)
        do {
            _ = try await client.fetchAttachment(selection: selection,
                attachment: AttachmentMetadata(path: metadata.path, blobSHA: "wrong-sha", byteSize: data.count))
            XCTFail("Wrong SHA must fail")
        } catch {}
    }
}

private struct Fixture {
    let root: URL
    let selection: RepositorySelection
    let configuration: StoreConfiguration
    let persistence: FileWorkspaceStore
    let bytes: AttachmentStore
    let service: TaskWorkspaceService
    let engine: SyncEngine
    let remote: AttachmentRemote
    var workspaceURL: URL { root.appendingPathComponent(FileWorkspaceStore.selectionKey(for: selection) + ".json") }
    init(version: Int = 1, cacheBudget: Int = AttachmentStore.maximumCacheBytes) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-tests-" + UUID().uuidString)
        selection = try RepositorySelection(owner: "owner", name: "repo", branch: "main", storePath: "todos")
        configuration = try StrictStoreConfigCodec().parseConfiguration(AttachmentRemote.configuration(version))
        persistence = FileWorkspaceStore(rootURL: root)
        bytes = AttachmentStore(rootURL: root, maximumCacheBytes: cacheBudget)
        service = TaskWorkspaceService(persistence: persistence, taskCodec: ObsidianTaskCodec(), attachmentStore: bytes)
        remote = try AttachmentRemote(version: version)
        engine = SyncEngine(gitHub: remote, persistence: persistence, configCodec: StrictStoreConfigCodec(), taskCodec: ObsidianTaskCodec(), attachmentStore: bytes)
        _ = try await engine.initialPull(selection: selection)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private actor AttachmentRemote: GitHubServing {
    private var snapshot: GitSnapshot
    private var binary: [String: Data] = [:]
    private var changes: [[RemoteChange]] = []
    private var staged: [RemoteChange] = []
    private var shouldFailConfirmation = false
    private var failFetch = false
    private var downloadFails = false
    private var staleHead = false
    static func configuration(_ version: Int) -> String {
        """
        schema_version = \(version)
        tasks_directory = "Tasks"
        projects_directory = "Projects"
        obsidian_link_prefix = ""
        default_state = "open"
        [[states]]
        id = "open"
        name = "Open"
        terminal = false
        [[states]]
        id = "done"
        name = "Done"
        terminal = true
        """
    }
    init(version: Int) throws {
        snapshot = try GitSnapshot(headCommitSHA: "h1", rootTreeSHA: "t1", files: [
            RemoteFile(path: "todos/.todo/config.toml", blobSHA: "config1", content: Self.configuration(version))])
    }
    func listRepositories() async throws -> [RepositorySummary] { [] }
    func discoverStorePaths(repository: RepositorySummary, branch: String) async throws -> [String] { ["todos"] }
    func fetchSnapshot(selection: RepositorySelection) async throws -> GitSnapshot {
        if failFetch { failFetch = false; throw OTodoError.transport(statusCode: nil, message: "confirmation failure") }
        return snapshot
    }
    func commit(selection: RepositorySelection, changes: [RemoteChange], against snapshot: GitSnapshot, message: String) async throws -> String {
        self.changes.append(changes); staged = changes; return "commit-\(self.changes.count)"
    }
    func updateReference(selection: RepositorySelection, to commitSHA: String, expectedHead: String) async throws {
        if staleHead {
            staleHead = false
            snapshot = try GitSnapshot(headCommitSHA: snapshot.headCommitSHA + "unrelated", rootTreeSHA: snapshot.rootTreeSHA + "unrelated", files: snapshot.files, attachments: snapshot.attachments)
            throw OTodoError.conflict(message: "Stale head")
        }
        var files = snapshot.files
        var attachments = snapshot.attachments
        for change in staged {
            if let data = change.binaryContent {
                binary[change.path] = data
                attachments.removeAll { $0.path == change.path }
                attachments.append(try AttachmentMetadata(path: change.path, blobSHA: GitBlobSHA.hexDigest(data), byteSize: data.count))
            } else {
                files.removeAll { $0.path == change.path }
                if let text = change.content { files.append(try RemoteFile(path: change.path, blobSHA: GitBlobSHA.hexDigest(Data(text.utf8)), content: text)) }
            }
        }
        snapshot = try GitSnapshot(headCommitSHA: commitSHA, rootTreeSHA: "tree-" + commitSHA, files: files, attachments: attachments)
        if shouldFailConfirmation { shouldFailConfirmation = false; failFetch = true }
    }
    func fetchAttachment(selection: RepositorySelection, attachment: AttachmentMetadata) async throws -> Data {
        if downloadFails { throw OTodoError.transport(statusCode: nil, message: "offline") }
        guard let data = binary[attachment.path] else { throw OTodoError.notFound(resource: attachment.path) }
        return data
    }
    func putAttachment(path: String, data: Data) {
        binary[path] = data
        let attachments = snapshot.attachments.filter { $0.path != path } + [try! AttachmentMetadata(path: path, blobSHA: GitBlobSHA.hexDigest(data), byteSize: data.count)]
        snapshot = try! GitSnapshot(headCommitSHA: snapshot.headCommitSHA + "x", rootTreeSHA: snapshot.rootTreeSHA + "x", files: snapshot.files, attachments: attachments)
    }
    func putMetadata(_ metadata: AttachmentMetadata) {
        snapshot = try! GitSnapshot(headCommitSHA: snapshot.headCommitSHA + "x", rootTreeSHA: snapshot.rootTreeSHA + "x", files: snapshot.files,
            attachments: snapshot.attachments.filter { $0.path != metadata.path } + [metadata])
    }
    func putText(path: String, text: String) {
        snapshot = try! GitSnapshot(headCommitSHA: snapshot.headCommitSHA + "x", rootTreeSHA: snapshot.rootTreeSHA + "x",
            files: snapshot.files.filter { $0.path != path } + [try! RemoteFile(path: path, blobSHA: GitBlobSHA.hexDigest(Data(text.utf8)), content: text)], attachments: snapshot.attachments)
    }
    func setSchema(_ version: Int) {
        let files = snapshot.files.filter { $0.path != "todos/.todo/config.toml" } + [try! RemoteFile(path: "todos/.todo/config.toml", blobSHA: "config\(version)", content: Self.configuration(version))]
        snapshot = try! GitSnapshot(headCommitSHA: snapshot.headCommitSHA + "x", rootTreeSHA: snapshot.rootTreeSHA + "x", files: files, attachments: snapshot.attachments)
    }
    func rejectNextHeadAsStale() { staleHead = true }
    func failNextConfirmation() { shouldFailConfirmation = true }
    func setDownloadFailure(_ value: Bool) { downloadFails = value }
    func committed() -> [[RemoteChange]] { changes }
}

private actor AttachmentHTTPTransport: HTTPTransport {
    let data: Data
    private var limit: Int?
    init(data: Data) { self.data = data }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: ["content": data.base64EncodedString(), "encoding": "base64"]))
    }
    func send(_ request: URLRequest, maximumResponseBodyBytes: Int) async throws -> HTTPResponse {
        limit = maximumResponseBodyBytes
        return try await send(request)
    }
    func recordedLimit() -> Int? { limit }
}

private actor AttachmentScriptTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private var captured: [URLRequest] = []
    init(objects: [[String: Any]]) throws {
        responses = try objects.map { HTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: $0)) }
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        captured.append(request)
        guard !responses.isEmpty else { throw OTodoError.transport(statusCode: nil, message: "Unexpected request") }
        return responses.removeFirst()
    }
    func requests() -> [URLRequest] { captured }
}
