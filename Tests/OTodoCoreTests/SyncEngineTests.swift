import Foundation
import XCTest
@testable import OTodoCore

final class SyncEngineTests: XCTestCase, @unchecked Sendable {
    func testInitialSparsePullPersistsValidatedStore() async throws {
        let f = try Fixture(twoTasks: true)
        let workspace = try await f.engine.initialPull(selection: f.selection)

        XCTAssertEqual(workspace.configuration.schemaVersion, 1)
        XCTAssertEqual(workspace.configuration.tasksDirectory, "Tasks")
        XCTAssertEqual(workspace.configuration.projectsDirectory, "Projects")
        XCTAssertEqual(workspace.configuration.states.map(\.id), ["open", "done"])
        XCTAssertEqual(workspace.knownProjectSlugs, ["alpha"])
        XCTAssertEqual(workspace.projects.first?.project.name, "Alpha")
        XCTAssertEqual(workspace.projects.first?.project.body, "# Alpha\n")
        XCTAssertEqual(workspace.projects.first?.content, "# Alpha\n")
        XCTAssertEqual(workspace.projects.first?.blobSHA, "project")
        XCTAssertEqual(workspace.tasks.map { $0.task.relativePath }, [Fixture.aRelative, Fixture.bRelative])
        XCTAssertEqual(workspace.tasks.map { $0.task.name }, ["A", "B"])
        XCTAssertEqual(workspace.tasks[0].task.projectSlugs, ["alpha"])
        XCTAssertEqual(workspace.tasks[0].task.body, "A body\n")
        XCTAssertEqual(workspace.tasks[0].blobSHA, "a1")
        XCTAssertEqual(workspace.baseHeadCommitSHA, "h1")
        XCTAssertEqual(workspace.baseRootTreeSHA, "t1")
        XCTAssertEqual(workspace.revision, 0)
        XCTAssertTrue(workspace.pendingChanges.isEmpty)
        XCTAssertTrue(workspace.conflicts.isEmpty)
        let saved = await f.store.current()
        XCTAssertEqual(try XCTUnwrap(saved), workspace)
        let calls = await f.gitHub.calls()
        XCTAssertEqual(calls.fetches, [f.selection])
        XCTAssertTrue(calls.commits.isEmpty)
        XCTAssertTrue(calls.updates.isEmpty)
    }

    func testUnrelatedRemotePullAndOfflinePushUseOneCommit() async throws {
        let f = try Fixture(twoTasks: true)
        let initial = try await f.engine.initialPull(selection: f.selection)
        let local = Fixture.record("A local", body: "local\n")
        let pending = try f.pending(local)
        try await f.store.save(try f.edit(initial, pending: pending), expectedRevision: 0)
        let remoteB = Fixture.record("B remote", body: "remote\n")
        let remote = try f.snapshot(head: "h2", tree: "t2", a: f.aOriginal, b: remoteB, bSHA: "b2")
        await f.gitHub.replace(remote)

        let report = try await f.engine.sync(selection: f.selection)

        XCTAssertEqual(report.pulledCount, 1)
        XCTAssertEqual(report.pushedCount, 1)
        XCTAssertTrue(report.conflicts.isEmpty)
        let saved = await f.store.current()
        let durable = try XCTUnwrap(saved)
        XCTAssertEqual(durable.revision, 3)
        XCTAssertEqual(durable.tasks.map { $0.task.name }, ["A local", "B remote"])
        XCTAssertTrue(durable.pendingChanges.isEmpty)
        XCTAssertTrue(durable.conflicts.isEmpty)
        let calls = await f.gitHub.calls()
        XCTAssertEqual(calls.commits.count, 1)
        XCTAssertEqual(calls.commits[0].against, remote)
        XCTAssertEqual(calls.commits[0].changes, [try RemoteChange(path: f.aPath, content: local)])
        XCTAssertEqual(calls.updates, [.init(commit: "c1", expected: "h2")])
        let branch = await f.gitHub.branch()
        XCTAssertEqual(branch.files.first { $0.path == f.aPath }?.content, local)
        XCTAssertEqual(branch.files.first { $0.path == f.bPath }?.content, remoteB)
    }

    func testSamePathDivergenceIsDurableConflictWithoutPush() async throws {
        let f = try Fixture()
        let initial = try await f.engine.initialPull(selection: f.selection)
        let local = Fixture.record("A local", body: "local\n")
        let pending = try f.pending(local)
        try await f.store.save(try f.edit(initial, pending: pending), expectedRevision: 0)
        let remoteText = Fixture.record("A remote", body: "remote\n")
        await f.gitHub.replace(try f.snapshot(head: "h2", tree: "t2", a: remoteText, aSHA: "a2"))

        let report = try await f.engine.sync(selection: f.selection)

        XCTAssertEqual(report.pulledCount, 0)
        XCTAssertEqual(report.pushedCount, 0)
        let conflict = try XCTUnwrap(report.conflicts.first)
        XCTAssertEqual(conflict.path, f.aPath)
        XCTAssertEqual(conflict.baseBlobSHA, "a1")
        XCTAssertEqual(conflict.remoteBlobSHA, "a2")
        XCTAssertEqual(conflict.localContent, local)
        XCTAssertEqual(conflict.remoteContent, remoteText)
        let saved = await f.store.current()
        let durable = try XCTUnwrap(saved)
        XCTAssertEqual(durable.revision, 2)
        XCTAssertEqual(durable.baseHeadCommitSHA, "h2")
        XCTAssertEqual(durable.tasks.first?.task.name, "A local")
        XCTAssertEqual(durable.pendingChanges, [pending])
        XCTAssertEqual(durable.conflicts, [conflict])
        let calls = await f.gitHub.calls()
        XCTAssertTrue(calls.commits.isEmpty)
        XCTAssertTrue(calls.updates.isEmpty)
    }

    func testContentEqualityConvergesAfterConfirmationCrash() async throws {
        let f = try Fixture()
        let initial = try await f.engine.initialPull(selection: f.selection)
        let local = Fixture.record("A local", body: "local\n")
        let pending = try f.pending(local)
        try await f.store.save(try f.edit(initial, pending: pending), expectedRevision: 0)
        await f.gitHub.failConfirmationFetch()

        do {
            _ = try await f.engine.sync(selection: f.selection)
            XCTFail("Expected confirmation failure")
        } catch let error as OTodoError {
            XCTAssertEqual(error, .transport(statusCode: nil, message: "crash"))
        }
        let strandedValue = await f.store.current()
        let stranded = try XCTUnwrap(strandedValue)
        XCTAssertEqual(stranded.revision, 2)
        XCTAssertEqual(stranded.pendingChanges, [pending])
        XCTAssertTrue(stranded.conflicts.isEmpty)

        let report = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(report.pushedCount, 1)
        let saved = await f.store.current()
        let durable = try XCTUnwrap(saved)
        XCTAssertEqual(durable.revision, 3)
        XCTAssertEqual(durable.tasks.first?.content, local)
        XCTAssertTrue(durable.pendingChanges.isEmpty)
        XCTAssertTrue(durable.conflicts.isEmpty)
        let calls = await f.gitHub.calls()
        XCTAssertEqual(calls.commits.count, 1)
        XCTAssertEqual(calls.updates, [.init(commit: "c1", expected: "h1")])
    }

    func testStaleHeadRetryPreservesUnrelatedRemoteData() async throws {
        let f = try Fixture(twoTasks: true)
        let initial = try await f.engine.initialPull(selection: f.selection)
        let local = Fixture.record("A local", body: "local\n")
        try await f.store.save(try f.edit(initial, pending: f.pending(local)), expectedRevision: 0)
        let racedB = Fixture.record("B raced", body: "raced\n")
        let race = try f.snapshot(head: "race", tree: "race-tree", a: f.aOriginal, b: racedB, bSHA: "b-race")
        await f.gitHub.raceNextUpdate(to: race)

        let report = try await f.engine.sync(selection: f.selection)

        XCTAssertEqual(report.pulledCount, 1)
        XCTAssertEqual(report.pushedCount, 1)
        let saved = await f.store.current()
        let durable = try XCTUnwrap(saved)
        XCTAssertEqual(durable.revision, 4)
        XCTAssertEqual(durable.tasks.map { $0.task.name }, ["A local", "B raced"])
        XCTAssertTrue(durable.pendingChanges.isEmpty)
        XCTAssertTrue(durable.conflicts.isEmpty)
        let calls = await f.gitHub.calls()
        XCTAssertEqual(calls.commits.count, 2)
        XCTAssertEqual(calls.commits[0].against.rootTreeSHA, "t1")
        XCTAssertEqual(calls.commits[1].against, race)
        XCTAssertEqual(calls.updates, [.init(commit: "c1", expected: "h1"), .init(commit: "c2", expected: "race")])
        let branch = await f.gitHub.branch()
        XCTAssertEqual(branch.files.first { $0.path == f.aPath }?.content, local)
        XCTAssertEqual(branch.files.first { $0.path == f.bPath }?.content, racedB)
    }

    func testCASContentionPreservesEditCreatedDuringReconciliation() async throws {
        let f = try Fixture(twoTasks: true)
        let initial = try await f.engine.initialPull(selection: f.selection)
        let local = Fixture.record("A concurrent", body: "concurrent\n")
        let pending = try f.pending(local, id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        await f.store.inject(try f.edit(initial, pending: pending))
        let remoteB = Fixture.record("B remote", body: "remote\n")
        let remote = try f.snapshot(head: "h2", tree: "t2", a: f.aOriginal, b: remoteB, bSHA: "b2")
        await f.gitHub.replace(remote)

        let report = try await f.engine.sync(selection: f.selection)

        XCTAssertEqual(report.pulledCount, 1)
        XCTAssertEqual(report.pushedCount, 1)
        let contentions = await f.store.contentions()
        XCTAssertEqual(contentions, 1)
        let saved = await f.store.current()
        let durable = try XCTUnwrap(saved)
        XCTAssertEqual(durable.revision, 3)
        XCTAssertEqual(durable.tasks.map { $0.task.name }, ["A concurrent", "B remote"])
        XCTAssertTrue(durable.pendingChanges.isEmpty)
        XCTAssertTrue(durable.conflicts.isEmpty)
        let calls = await f.gitHub.calls()
        XCTAssertEqual(calls.commits.count, 1)
        XCTAssertEqual(calls.commits[0].against, remote)
        XCTAssertEqual(calls.commits[0].changes, [try RemoteChange(path: f.aPath, content: local)])
        XCTAssertEqual(calls.updates, [.init(commit: "c1", expected: "h2")])
    }

    func testInflightV1ThenCoalescedV2LeavesV2PendingRebasedOnV1Blob() async throws {
        let f = try Fixture()
        let initial = try await f.engine.initialPull(selection: f.selection)
        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let v1 = Fixture.record("A v1", body: "v1\n")
        let p1 = try f.pending(v1, id: id)
        try await f.store.save(try f.edit(initial, pending: p1), expectedRevision: 0)
        let v2 = Fixture.record("A v2", body: "v2\n")
        let p2 = try f.pending(v2, id: id)
        let concurrentV2 = try f.edit(initial, pending: p2, revision: 3)
        await f.gitHub.onNextCommit { try await f.store.install(concurrentV2) }

        let report = try await f.engine.sync(selection: f.selection)

        XCTAssertTrue(report.conflicts.isEmpty)
        let remote = await f.gitHub.branch()
        let v1File = try XCTUnwrap(remote.files.first { $0.path == f.aPath })
        XCTAssertEqual(v1File.content, v1)
        let saved = await f.store.current()
        let durable = try XCTUnwrap(saved)
        XCTAssertEqual(durable.revision, 4)
        XCTAssertEqual(durable.tasks.first?.task.name, "A v2")
        XCTAssertEqual(durable.tasks.first?.blobSHA, v1File.blobSHA)
        let rebased = try XCTUnwrap(durable.pendingChanges.first)
        XCTAssertEqual(rebased.id, id)
        XCTAssertEqual(rebased.baseBlobSHA, v1File.blobSHA)
        XCTAssertEqual(rebased.content, v2)
        XCTAssertEqual(rebased.createdAt, p1.createdAt)
        XCTAssertTrue(durable.conflicts.isEmpty)
        let calls = await f.gitHub.calls()
        XCTAssertEqual(calls.commits.count, 1)
        XCTAssertEqual(calls.commits[0].changes, [try RemoteChange(path: f.aPath, content: v1)])
        XCTAssertEqual(calls.updates, [.init(commit: "c1", expected: "h1")])
    }

    func testLocalDeletionPushesAndConfirms() async throws {
        let f = try Fixture()
        let initial = try await f.engine.initialPull(selection: f.selection)
        let pending = try f.deletion()
        try await f.store.save(
            try f.deleting(initial, pending: pending),
            expectedRevision: initial.revision
        )

        let report = try await f.engine.sync(selection: f.selection)

        XCTAssertEqual(report.pulledCount, 0)
        XCTAssertEqual(report.pushedCount, 1)
        XCTAssertTrue(report.conflicts.isEmpty)
        let saved = await f.store.current()
        let durable = try XCTUnwrap(saved)
        XCTAssertEqual(durable.revision, 3)
        XCTAssertTrue(durable.tasks.isEmpty)
        XCTAssertTrue(durable.pendingChanges.isEmpty)
        XCTAssertTrue(durable.conflicts.isEmpty)
        let calls = await f.gitHub.calls()
        XCTAssertEqual(calls.commits.count, 1)
        XCTAssertEqual(
            calls.commits[0].changes,
            [try RemoteChange(path: f.aPath, content: nil)]
        )
        XCTAssertEqual(calls.updates, [.init(commit: "c1", expected: "h1")])
        let branch = await f.gitHub.branch()
        XCTAssertFalse(branch.files.contains(where: { $0.path == f.aPath }))
    }

    func testRemoteEditConflictsWithLocalDeletionWithoutRestoringTask() async throws {
        let f = try Fixture()
        let initial = try await f.engine.initialPull(selection: f.selection)
        let pending = try f.deletion()
        try await f.store.save(
            try f.deleting(initial, pending: pending),
            expectedRevision: initial.revision
        )
        let remoteContent = Fixture.record("A remote", body: "remote\n")
        await f.gitHub.replace(
            try f.snapshot(head: "h2", tree: "t2", a: remoteContent, aSHA: "a2")
        )

        let report = try await f.engine.sync(selection: f.selection)

        XCTAssertEqual(report.pulledCount, 0)
        XCTAssertEqual(report.pushedCount, 0)
        let conflict = try XCTUnwrap(report.conflicts.first)
        XCTAssertEqual(conflict.path, f.aPath)
        XCTAssertEqual(conflict.baseBlobSHA, "a1")
        XCTAssertEqual(conflict.remoteBlobSHA, "a2")
        XCTAssertNil(conflict.localContent)
        XCTAssertEqual(conflict.remoteContent, remoteContent)
        let saved = await f.store.current()
        let durable = try XCTUnwrap(saved)
        XCTAssertEqual(durable.revision, 2)
        XCTAssertTrue(durable.tasks.isEmpty)
        XCTAssertEqual(durable.pendingChanges, [pending])
        XCTAssertEqual(durable.conflicts, [conflict])
        let calls = await f.gitHub.calls()
        XCTAssertTrue(calls.commits.isEmpty)
        XCTAssertTrue(calls.updates.isEmpty)
    }

    func testReschedulingConcurrentSaveRejectsWholeBatchWithoutOverwritingNewerEdit() async throws {
        let f = try Fixture(twoTasks: true)
        let initial = try await f.engine.initialPull(selection: f.selection)
        let pending = try f.pending(Fixture.record("Concurrent edit", body: "Newer body\n"))
        let concurrent = try f.edit(initial, pending: pending)
        await f.store.inject(concurrent)
        let service = TaskWorkspaceService(persistence: f.store, taskCodec: ObsidianTaskCodec())

        do {
            _ = try await service.rescheduleTasks(
                selection: f.selection, expectedTasks: initial.tasks.map(\.task),
                dueDate: .set(try CivilDate(rawValue: "2027-08-09")), dueTime: .preserve
            )
            XCTFail("Expected optimistic save conflict")
        } catch let error as OTodoError {
            guard case .conflict = error else { return XCTFail("Expected conflict, got \(error)") }
        }

        let saved = await f.store.current()
        XCTAssertEqual(try XCTUnwrap(saved), concurrent)
    }

    func testRescheduledBatchSyncsCanonicalSchedulesWithoutLosingOtherContent() async throws {
        let f = try Fixture(twoTasks: true)
        let initial = try await f.engine.initialPull(selection: f.selection)
        let service = TaskWorkspaceService(persistence: f.store, taskCodec: ObsidianTaskCodec())
        var update = TaskUpdate(task: initial.tasks[0].task)
        update.name = "Offline edit"
        update.body = "Keep offline body\n\n- [ ] Follow up\n"
        update.tags = ["local"]
        let edited = try await service.editTask(
            selection: f.selection, id: initial.tasks[0].task.id,
            expectedTask: initial.tasks[0].task, update: update
        )
        let beforeBatchValue = await f.store.current()
        let beforeBatch = try XCTUnwrap(beforeBatchValue)
        let originalPending = try XCTUnwrap(beforeBatch.pendingChanges.first)
        let date = try CivilDate(rawValue: "2027-03-04")
        let time = try CivilTime(rawValue: "09:30")
        let rescheduled = try await service.rescheduleTasks(
            selection: f.selection, expectedTasks: [edited, initial.tasks[1].task],
            dueDate: .set(date), dueTime: .set(time)
        )
        let queuedValue = await f.store.current()
        let queued = try XCTUnwrap(queuedValue)
        XCTAssertEqual(queued.pendingChanges.count, 2)
        let coalesced = try XCTUnwrap(queued.pendingChanges.first { $0.path == f.aPath })
        XCTAssertEqual(coalesced.id, originalPending.id)
        XCTAssertEqual(coalesced.baseBlobSHA, originalPending.baseBlobSHA)
        XCTAssertEqual(coalesced.createdAt, originalPending.createdAt)

        let report = try await f.engine.sync(selection: f.selection)

        XCTAssertEqual(report.pushedCount, 2)
        XCTAssertTrue(report.conflicts.isEmpty)
        let saved = await f.store.current()
        let durable = try XCTUnwrap(saved)
        XCTAssertTrue(durable.pendingChanges.isEmpty)
        XCTAssertEqual(durable.tasks.map(\.task), rescheduled)
        let calls = await f.gitHub.calls()
        XCTAssertEqual(calls.commits.count, 1)
        let branch = await f.gitHub.branch()
        for document in durable.tasks {
            let remote = try XCTUnwrap(branch.files.first {
                $0.path == f.path(document.task.relativePath)
            })
            let parsed = try ObsidianTaskCodec().parseTask(
                id: document.task.id, relativePath: document.task.relativePath,
                text: remote.content, configuration: durable.configuration
            )
            XCTAssertEqual(parsed, document.task)
            XCTAssertEqual(parsed.dueDate, date)
            XCTAssertEqual(parsed.dueTime, time)
        }
        XCTAssertEqual(durable.tasks[0].task.body, update.body)
        XCTAssertEqual(durable.tasks[0].task.tags, update.tags)
        XCTAssertEqual(durable.tasks[0].task.projectSlugs, edited.projectSlugs)
        XCTAssertEqual(branch.files.first { $0.path == f.path("Projects/alpha.md") }?.content, "# Alpha\n")
    }

    func testProjectCreationAndItsTaskReferenceSyncInOneCommit() async throws {
        let f = try Fixture()
        let initial = try await f.engine.initialPull(selection: f.selection)
        let taskContent = Fixture.record(
            "A local",
            projects: ["side-project"],
            body: "local\n"
        )
        let taskPending = try f.pending(
            taskContent,
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        )
        let edited = try f.edit(initial, pending: taskPending)
        let projectPath = f.path("Projects/side-project.md")
        let projectContent = "# Side Project\n"
        let projectPending = try PendingChange(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            path: projectPath,
            baseBlobSHA: nil,
            content: projectContent,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let local = try WorkspaceState(
            selection: f.selection,
            configuration: initial.configuration,
            knownProjectSlugs: ["alpha", "side-project"],
            tasks: edited.tasks,
            baseHeadCommitSHA: initial.baseHeadCommitSHA,
            baseRootTreeSHA: initial.baseRootTreeSHA,
            pendingChanges: [taskPending, projectPending],
            conflicts: [],
            revision: initial.revision + 1
        )
        try await f.store.save(local, expectedRevision: initial.revision)

        let report = try await f.engine.sync(selection: f.selection)

        XCTAssertEqual(report.pulledCount, 0)
        XCTAssertEqual(report.pushedCount, 2)
        XCTAssertTrue(report.conflicts.isEmpty)
        let saved = await f.store.current()
        let durable = try XCTUnwrap(saved)
        XCTAssertEqual(durable.knownProjectSlugs, ["alpha", "side-project"])
        XCTAssertEqual(durable.tasks[0].task.projectSlugs, ["side-project"])
        XCTAssertTrue(durable.pendingChanges.isEmpty)
        let calls = await f.gitHub.calls()
        XCTAssertEqual(calls.commits.count, 1)
        XCTAssertEqual(
            calls.commits[0].changes,
            [
                try RemoteChange(path: projectPath, content: projectContent),
                try RemoteChange(path: f.aPath, content: taskContent),
            ]
        )
        let branch = await f.gitHub.branch()
        XCTAssertEqual(
            branch.files.first { $0.path == projectPath }?.content,
            projectContent
        )
    }
}

extension SyncEngineTests {
    func testExplicitInProgressSetupPreservesCustomStoreAndOfflineTaskEdits() async throws {
        let f = try Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = FileWorkspaceStore(rootURL: directory)
        let engine = SyncEngine(
            gitHub: f.gitHub, persistence: disk,
            configCodec: StrictStoreConfigCodec(), taskCodec: ObsidianTaskCodec()
        )
        let originalConfig = [
            "# Keep this store's formatting and workflow order.",
            "schema_version = 2", "tasks_directory = 'Work'", "projects_directory = 'Areas'",
            "obsidian_link_prefix = 'Home'", "default_state = 'active'",
            "", "[[states]]", "id = 'blocked'", "name = 'Waiting'", "terminal = false",
            "", "[[states]]", "id = 'active'", "name = 'Underway'", "terminal = false",
            "", "[[states]]", "id = 'open'", "name = 'Inbox'", "terminal = false",
            "", "[[states]]", "id = 'done'", "name = 'Finished'", "terminal = true",
            "", "[[states]]", "id = 'cancelled'", "name = 'Cancelled'", "terminal = true",
            "# No final newline",
        ].joined(separator: "\r\n")
        let relativePath = Fixture.aRelative.replacingOccurrences(of: "Tasks/", with: "Work/")
        let taskPath = f.path(relativePath)
        let configPath = f.path(".todo/config.toml")
        let originalTask = Fixture.record("A", body: "Keep my notes\n")
        let original = try GitSnapshot(headCommitSHA: "custom", rootTreeSHA: "custom-tree", files: [
            try RemoteFile(path: configPath, blobSHA: "config", content: originalConfig),
            try RemoteFile(path: taskPath, blobSHA: "a1", content: originalTask),
        ])
        await f.gitHub.replace(original)
        let initial = try await engine.initialPull(selection: f.selection)
        _ = try await engine.sync(selection: f.selection)
        let unchanged = await f.gitHub.branch()
        XCTAssertEqual(unchanged, original, "Pull and ordinary sync must not migrate the workflow")
        XCTAssertFalse(initial.configuration.states.contains(where: \.isInProgress))

        let service = TaskWorkspaceService(persistence: disk, taskCodec: ObsidianTaskCodec())
        var update = TaskUpdate(task: initial.tasks[0].task)
        update.name = "Pending offline name"
        let edited = try await service.editTask(
            selection: f.selection, id: initial.tasks[0].task.id,
            expectedTask: initial.tasks[0].task, update: update
        )
        let beforeSetup = try await service.loadWorkspace(selection: f.selection)

        let configured = try await engine.addInProgressState(selection: f.selection)

        XCTAssertEqual(configured.configuration.states, initial.configuration.states + [.inProgress])
        XCTAssertEqual(configured.configuration.defaultState, "active")
        XCTAssertEqual(configured.configuration.schemaVersion, 2)
        XCTAssertEqual(configured.configuration.tasksDirectory, "Work")
        XCTAssertEqual(configured.configuration.projectsDirectory, "Areas")
        XCTAssertEqual(configured.configuration.obsidianLinkPrefix, "Home")
        XCTAssertEqual(configured.tasks.map(\.task), [edited])
        XCTAssertEqual(configured.pendingChanges, beforeSetup.pendingChanges)
        let configuredBranch = await f.gitHub.branch()
        XCTAssertEqual(configuredBranch.files.first { $0.path == taskPath }?.content, originalTask)
        let publishedConfig = try XCTUnwrap(configuredBranch.files.first { $0.path == configPath }?.content)
        XCTAssertEqual(Array(publishedConfig.utf8.prefix(originalConfig.utf8.count)), Array(originalConfig.utf8))
        let appended = String(publishedConfig.dropFirst(originalConfig.count))
        XCTAssertFalse(appended.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertEqual(try StrictStoreConfigCodec().parseConfiguration(publishedConfig), configured.configuration)

        // A fresh disk-backed service has no network dependency: state edits survive reload,
        // coalesce with the existing edit, and later publish through ordinary sync.
        let offline = TaskWorkspaceService(
            persistence: FileWorkspaceStore(rootURL: directory), taskCodec: ObsidianTaskCodec()
        )
        var start = TaskUpdate(task: edited)
        start.state = WorkflowState.inProgress.id
        let started = try await offline.editTask(
            selection: f.selection, id: edited.id, expectedTask: edited, update: start
        )
        let reloaded = TaskWorkspaceService(
            persistence: FileWorkspaceStore(rootURL: directory), taskCodec: ObsidianTaskCodec()
        )
        let durable = try await reloaded.loadWorkspace(selection: f.selection)
        XCTAssertEqual(durable.tasks.map(\.task), [started])
        XCTAssertEqual(durable.tasks[0].task.state, "in-progress")
        XCTAssertEqual(durable.pendingChanges.map(\.id), beforeSetup.pendingChanges.map(\.id))
        let stillRemote = await f.gitHub.branch()
        XCTAssertEqual(stillRemote, configuredBranch)
        _ = try await engine.sync(selection: f.selection)
        let synced = await f.gitHub.branch()
        let remoteTask = try XCTUnwrap(synced.files.first { $0.path == taskPath })
        XCTAssertEqual(
            try ObsidianTaskCodec().parseTask(
                id: started.id, relativePath: relativePath, text: remoteTask.content,
                configuration: configured.configuration
            ),
            started
        )
        XCTAssertEqual(synced.files.first { $0.path == configPath }?.content, publishedConfig)
    }

    func testInProgressSetupReusesCustomCanonicalStateWithoutPublishing() async throws {
        let f = try Fixture()
        let initial = try await f.engine.initialPull(selection: f.selection)
        let config = Fixture.config + "\n[[states]]\nid = 'in-progress'\nname = 'Doing'\nterminal = false\n"
        let remote = try replacingConfiguration(in: await f.gitHub.branch(), with: config)
        await f.gitHub.replace(remote)

        let configured = try await f.engine.addInProgressState(selection: f.selection)
        let repeated = try await f.engine.addInProgressState(selection: f.selection)

        XCTAssertEqual(configured.configuration.states, initial.configuration.states + [
            try WorkflowState(id: "in-progress", name: "Doing", isTerminal: false),
        ])
        XCTAssertEqual(repeated.configuration, configured.configuration)
        XCTAssertTrue(try XCTUnwrap(configured.configuration.states.last).isInProgress)
        let branch = await f.gitHub.branch()
        XCTAssertEqual(branch, remote, "Idempotent setup must not create a new remote commit")
    }

    func testInProgressSetupRejectsTerminalCollisionWithoutChangingEitherStore() async throws {
        let f = try Fixture()
        let config = Fixture.config + "\n[[states]]\nid = 'in-progress'\nname = 'Archived'\nterminal = true\n"
        let remote = try replacingConfiguration(in: await f.gitHub.branch(), with: config)
        await f.gitHub.replace(remote)
        let initial = try await f.engine.initialPull(selection: f.selection)
        XCTAssertFalse(try XCTUnwrap(initial.configuration.states.last).isInProgress)

        do {
            _ = try await f.engine.addInProgressState(selection: f.selection)
            XCTFail("A terminal canonical ID must not be reinterpreted")
        } catch let error as OTodoError {
            guard case .conflict = error else { return XCTFail("Expected conflict, got \(error)") }
        }

        let branch = await f.gitHub.branch()
        let saved = await f.store.current()
        XCTAssertEqual(branch, remote)
        XCTAssertEqual(saved, initial)
    }

    func testInProgressSetupRejectsPendingConfigurationAndOrphanedConflict() async throws {
        for isConflict in [false, true] {
            let f = try Fixture()
            let initial = try await f.engine.initialPull(selection: f.selection)
            let path = f.path(".todo/config.toml")
            let content = Fixture.config + "\n# local configuration work\n"
            let pending = try PendingChange(
                id: UUID(), path: path, baseBlobSHA: "config", content: content,
                createdAt: Date(timeIntervalSince1970: 100)
            )
            let conflict = try SyncConflict(
                path: path, baseBlobSHA: "config", remoteBlobSHA: "config",
                localContent: content, remoteContent: Fixture.config
            )
            let local = try WorkspaceState(
                selection: f.selection, configuration: initial.configuration,
                knownProjectSlugs: initial.knownProjectSlugs, tasks: initial.tasks,
                baseHeadCommitSHA: initial.baseHeadCommitSHA, baseRootTreeSHA: initial.baseRootTreeSHA,
                pendingChanges: isConflict ? [] : [pending],
                conflicts: isConflict ? [conflict] : [], revision: initial.revision + 1
            )
            try await f.store.save(local, expectedRevision: initial.revision)
            let original = await f.gitHub.branch()

            do {
                _ = try await f.engine.addInProgressState(selection: f.selection)
                XCTFail("Local configuration work must be resolved explicitly")
            } catch let error as OTodoError {
                guard case .conflict = error else { return XCTFail("Expected conflict, got \(error)") }
            }

            let branch = await f.gitHub.branch()
            let saved = await f.store.current()
            XCTAssertEqual(branch, original)
            XCTAssertEqual(saved, local)
        }
    }

    func testInProgressSetupSurfacesStaleHeadWithoutRetryingOrPublishingPendingTasks() async throws {
        let f = try Fixture(twoTasks: true)
        let initial = try await f.engine.initialPull(selection: f.selection)
        let pending = try f.pending(Fixture.record("Local A", body: "Offline\n"))
        let local = try f.edit(initial, pending: pending)
        try await f.store.save(local, expectedRevision: initial.revision)
        let raced = try f.snapshot(
            head: "raced", tree: "raced-tree", a: f.aOriginal,
            b: Fixture.record("Remote B", body: "Concurrent\n"), bSHA: "b-raced"
        )
        await f.gitHub.raceNextUpdate(to: raced)

        do {
            _ = try await f.engine.addInProgressState(selection: f.selection)
            XCTFail("A stale head must surface rather than silently retrying setup")
        } catch let error as OTodoError {
            guard case .conflict = error else { return XCTFail("Expected conflict, got \(error)") }
        }

        let branch = await f.gitHub.branch()
        let saved = await f.store.current()
        XCTAssertEqual(branch, raced)
        XCTAssertEqual(saved, local)
    }

    private func replacingConfiguration(in snapshot: GitSnapshot, with content: String) throws -> GitSnapshot {
        try GitSnapshot(
            headCommitSHA: "configured", rootTreeSHA: "configured-tree",
            files: snapshot.files.map { file in
                if file.path.hasSuffix("/.todo/config.toml") {
                    return try RemoteFile(path: file.path, blobSHA: "custom-config", content: content)
                }
                return file
            },
            attachments: snapshot.attachments
        )
    }
}

private struct Fixture {
    static let aRelative = "Tasks/01ARZ3NDEKTSV4RRFFQ69G5FAV.md"
    static let bRelative = "Tasks/01ARZ3NDEKTSV4RRFFQ69G5FAW.md"
    static let config = [
        "schema_version = 1", "tasks_directory = \"Tasks\"", "projects_directory = \"Projects\"",
        "obsidian_link_prefix = \"Vault\"", "default_state = \"open\"", "", "[[states]]",
        "id = \"open\"", "name = \"Open\"", "terminal = false", "", "[[states]]",
        "id = \"done\"", "name = \"Done\"", "terminal = true", "",
    ].joined(separator: "\n")

    let selection: RepositorySelection
    let store: MemoryWorkspaceStore
    let gitHub: StatefulGitHub
    let engine: SyncEngine
    let aOriginal: String
    let bOriginal: String

    init(twoTasks: Bool = false) throws {
        let selection = try RepositorySelection(owner: "o", name: "r", branch: "main", storePath: "vault")
        let store = MemoryWorkspaceStore()
        let aOriginal = Self.record("A", projects: ["alpha"], body: "A body\n")
        let bOriginal = Self.record("B", body: "B body\n")
        let initial = try Self.makeSnapshot(
            selection,
            head: "h1",
            tree: "t1",
            a: aOriginal,
            b: twoTasks ? bOriginal : nil
        )
        let gitHub = StatefulGitHub(initial)
        self.selection = selection
        self.store = store
        self.aOriginal = aOriginal
        self.bOriginal = bOriginal
        self.gitHub = gitHub
        self.engine = SyncEngine(
            gitHub: gitHub,
            persistence: store,
            configCodec: StrictStoreConfigCodec(),
            taskCodec: ObsidianTaskCodec()
        )
    }

    var aPath: String { path(Self.aRelative) }
    var bPath: String { path(Self.bRelative) }
    func path(_ relative: String) -> String { selection.storePath + "/" + relative }

    static func record(_ name: String, projects: [String] = [], body: String) -> String {
        var lines = ["---", "name: \(name)", "state: open"]
        if projects.isEmpty { lines.append("projects: []") }
        else {
            lines.append("projects:")
            lines += projects.map { "  - \"[[Vault/Projects/\($0)]]\"" }
        }
        lines += ["tags: []", "---"]
        return lines.joined(separator: "\n") + "\n" + body
    }

    func snapshot(head: String, tree: String, a: String, b: String? = nil, aSHA: String = "a1", bSHA: String = "b1") throws -> GitSnapshot {
        try Self.makeSnapshot(selection, head: head, tree: tree, a: a, b: b, aSHA: aSHA, bSHA: bSHA)
    }

    private static func makeSnapshot(_ selection: RepositorySelection, head: String, tree: String, a: String, b: String?, aSHA: String = "a1", bSHA: String = "b1") throws -> GitSnapshot {
        let prefix = selection.storePath + "/"
        var files = [
            try RemoteFile(path: prefix + aRelative, blobSHA: aSHA, content: a),
            try RemoteFile(path: prefix + "Projects/alpha.md", blobSHA: "project", content: "# Alpha\n"),
            try RemoteFile(path: prefix + ".todo/config.toml", blobSHA: "config", content: config),
        ]
        if let b { files.insert(try RemoteFile(path: prefix + bRelative, blobSHA: bSHA, content: b), at: 0) }
        return try GitSnapshot(headCommitSHA: head, rootTreeSHA: tree, files: files)
    }

    func pending(_ content: String, id: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!) throws -> PendingChange {
        try PendingChange(id: id, path: aPath, baseBlobSHA: "a1", content: content, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func deletion(
        id: UUID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    ) throws -> PendingChange {
        try PendingChange(
            id: id,
            path: aPath,
            baseBlobSHA: "a1",
            content: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func deleting(_ base: WorkspaceState, pending: PendingChange) throws -> WorkspaceState {
        try WorkspaceState(
            selection: selection,
            configuration: base.configuration,
            knownProjectSlugs: base.knownProjectSlugs,
            tasks: base.tasks.filter { $0.task.relativePath != Self.aRelative },
            baseHeadCommitSHA: base.baseHeadCommitSHA,
            baseRootTreeSHA: base.baseRootTreeSHA,
            pendingChanges: [pending],
            conflicts: [],
            revision: base.revision + 1,
            projects: base.projects
        )
    }

    func edit(_ base: WorkspaceState, pending: PendingChange, revision: UInt64? = nil) throws -> WorkspaceState {
        var tasks = base.tasks
        let index = try XCTUnwrap(tasks.firstIndex { $0.task.relativePath == Self.aRelative })
        let content = try XCTUnwrap(pending.content)
        let task = try ObsidianTaskCodec().parseTask(id: tasks[index].task.id, relativePath: Self.aRelative, text: content, configuration: base.configuration)
        tasks[index] = TaskDocument(task: task, content: content, blobSHA: pending.baseBlobSHA)
        return try WorkspaceState(selection: selection, configuration: base.configuration, knownProjectSlugs: base.knownProjectSlugs, tasks: tasks, baseHeadCommitSHA: base.baseHeadCommitSHA, baseRootTreeSHA: base.baseRootTreeSHA, pendingChanges: [pending], conflicts: [], revision: revision ?? base.revision + 1, projects: base.projects)
    }
}

private actor MemoryWorkspaceStore: WorkspacePersisting {
    private var value: WorkspaceState?
    private var injected: WorkspaceState?
    private var contentionCount = 0

    func load(selection: RepositorySelection) async throws -> WorkspaceState? {
        value?.selection == selection ? value : nil
    }

    func save(_ candidate: WorkspaceState, expectedRevision: UInt64?) async throws {
        if expectedRevision != nil, let injected {
            self.injected = nil
            value = injected
            contentionCount += 1
            throw OTodoError.conflict(message: "CAS contention")
        }
        if let expectedRevision {
            guard value?.revision == expectedRevision, candidate.revision == expectedRevision + 1 else {
                throw OTodoError.conflict(message: "stale workspace")
            }
        } else {
            guard value == nil, candidate.revision == 0 else { throw OTodoError.conflict(message: "workspace exists") }
        }
        value = candidate
    }

    func current() -> WorkspaceState? { value }
    func inject(_ workspace: WorkspaceState) { injected = workspace }
    func contentions() -> Int { contentionCount }
    func install(_ workspace: WorkspaceState) throws {
        guard let current = value, workspace.revision == current.revision + 1 else {
            throw OTodoError.corruptLocalState(message: "invalid concurrent revision")
        }
        value = workspace
    }
}

private actor StatefulGitHub: GitHubServing {
    struct CommitCall: Sendable { let changes: [RemoteChange]; let against: GitSnapshot }
    struct UpdateCall: Sendable, Equatable { let commit: String; let expected: String }
    struct Calls: Sendable { let fetches: [RepositorySelection]; let commits: [CommitCall]; let updates: [UpdateCall] }

    private var current: GitSnapshot
    private var created: [String: GitSnapshot] = [:]
    private var fetchLog: [RepositorySelection] = []
    private var commitLog: [CommitCall] = []
    private var updateLog: [UpdateCall] = []
    private var sequence = 0
    private var race: GitSnapshot?
    private var failAfterUpdate = false
    private var failFetch = false
    private var commitHook: (@Sendable () async throws -> Void)?

    init(_ snapshot: GitSnapshot) { current = snapshot }
    func listRepositories() async throws -> [RepositorySummary] { [] }
    func discoverStorePaths(repository: RepositorySummary, branch: String) async throws -> [String] { [] }

    func fetchSnapshot(selection: RepositorySelection) async throws -> GitSnapshot {
        fetchLog.append(selection)
        if failFetch {
            failFetch = false
            throw OTodoError.transport(statusCode: nil, message: "crash")
        }
        return current
    }

    func commit(selection: RepositorySelection, changes: [RemoteChange], against snapshot: GitSnapshot, message: String) async throws -> String {
        commitLog.append(.init(changes: changes, against: snapshot))
        guard snapshot.headCommitSHA == current.headCommitSHA else { throw OTodoError.conflict(message: "stale commit") }
        sequence += 1
        let sha = "c\(sequence)"
        var files = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, $0) })
        for (index, change) in changes.enumerated() {
            if let content = change.content {
                files[change.path] = try RemoteFile(path: change.path, blobSHA: "c\(sequence)-b\(index)", content: content)
            } else { files.removeValue(forKey: change.path) }
        }
        created[sha] = try GitSnapshot(headCommitSHA: sha, rootTreeSHA: "c\(sequence)-tree", files: files.values.sorted { $0.path < $1.path })
        let hook = commitHook
        commitHook = nil
        try await hook?()
        return sha
    }

    func updateReference(selection: RepositorySelection, to commitSHA: String, expectedHead: String) async throws {
        updateLog.append(.init(commit: commitSHA, expected: expectedHead))
        if let race {
            self.race = nil
            current = race
            throw OTodoError.conflict(message: "race")
        }
        guard current.headCommitSHA == expectedHead else { throw OTodoError.conflict(message: "stale ref") }
        guard let committed = created[commitSHA] else {
            throw OTodoError.notFound(resource: "commit \(commitSHA)")
        }
        current = committed
        if failAfterUpdate { failAfterUpdate = false; failFetch = true }
    }

    func replace(_ snapshot: GitSnapshot) { current = snapshot }
    func raceNextUpdate(to snapshot: GitSnapshot) { race = snapshot }
    func failConfirmationFetch() { failAfterUpdate = true }
    func onNextCommit(_ hook: @escaping @Sendable () async throws -> Void) { commitHook = hook }
    func branch() -> GitSnapshot { current }
    func calls() -> Calls { Calls(fetches: fetchLog, commits: commitLog, updates: updateLog) }
}

extension SyncEngineTests {
    func testDifferentFileCycleWithholdsRelatedOutboxButPublishesIndependentWorkAndRepair() async throws {
        let f = try SubtaskSyncFixture()
        let initial = try await f.engine.initialPull(selection: f.selection)
        let a = try f.pending(1, parent: 2, name: "Local A")
        let c = try f.pending(3, name: "Independent")
        try await f.install(initial, pending: [a, c])
        await f.gitHub.replace(try f.snapshot(head: "remote", parents: [2: 1]))
        let report = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(report.pushedCount, 1)
        XCTAssertTrue(report.conflicts.isEmpty)
        let blocked = try await f.workspace()
        XCTAssertEqual(blocked.pendingChanges, [a])
        XCTAssertEqual(Set(blocked.relationshipBlocks.filter { $0.code == "parent_cycle" }.flatMap(\.relatedTaskIDs)),
                       Set([try f.id(1), try f.id(2)]))
        let branch = await f.gitHub.branch()
        XCTAssertNil(try f.task(1, in: branch).parentID)
        XCTAssertEqual(try f.task(2, in: branch).parentID, try f.id(1))
        let task = try XCTUnwrap(blocked.tasks.first { $0.task.id == (try? f.id(1)) }?.task)
        var update = TaskUpdate(task: task)
        update.parentID = nil
        _ = try await f.service.editTask(selection: f.selection, id: task.id, expectedTask: task, update: update)
        let repaired = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(repaired.pushedCount, 1)
        let final = try await f.workspace()
        XCTAssertTrue(final.pendingChanges.isEmpty)
        XCTAssertTrue(final.relationshipBlocks.isEmpty)
    }

    func testWithheldParentCreationCannotPublishOrphanAndResolutionRecomputes() async throws {
        let f = try SubtaskSyncFixture()
        let initial = try await f.engine.initialPull(selection: f.selection)
        let parent = try f.pending(4, name: "New parent", base: nil)
        let child = try f.pending(1, parent: 4)
        let safe = try f.pending(3, name: "Independent")
        let conflict = try SyncConflict(path: parent.path, baseBlobSHA: nil, remoteBlobSHA: nil,
                                        localContent: parent.content, remoteContent: nil)
        try await f.install(initial, pending: [parent, child, safe], conflicts: [conflict])
        _ = try await f.engine.sync(selection: f.selection)
        let blocked = try await f.workspace()
        XCTAssertEqual(blocked.pendingChanges, [parent, child])
        XCTAssertEqual(blocked.conflicts, [conflict])
        let parentID = try f.id(4)
        XCTAssertTrue(blocked.relationshipBlocks.contains { $0.code == "missing_parent_reference" && $0.relatedTaskIDs.contains(parentID) })
        let calls = await f.gitHub.calls()
        XCTAssertEqual(calls.commits.flatMap(\.changes).map(\.path), [safe.path])
        _ = try await f.service.keepLocalConflict(selection: f.selection, path: parent.path)
        let report = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(report.pushedCount, 2)
        let branch = await f.gitHub.branch()
        XCTAssertEqual(try f.task(1, in: branch).parentID, try f.id(4))
        XCTAssertEqual(try f.task(4, in: branch).name, "New parent")
        let final = try await f.workspace()
        XCTAssertTrue(final.relationshipBlocks.isEmpty)
    }

    func testWithheldDetachCannotIntroducePublishCycle() async throws {
        let f = try SubtaskSyncFixture(parents: [1: 2])
        let initial = try await f.engine.initialPull(selection: f.selection)
        let detach = try f.pending(1, name: "Detached locally")
        let reparent = try f.pending(2, parent: 1)
        let safe = try f.pending(3, name: "Independent")
        try await f.install(initial, pending: [detach, reparent, safe])
        await f.gitHub.replace(try f.snapshot(head: "remote", parents: [1: 2], names: [1: "Remote A"]))
        _ = try await f.engine.sync(selection: f.selection)
        let blocked = try await f.workspace()
        XCTAssertEqual(blocked.pendingChanges, [detach, reparent])
        XCTAssertEqual(blocked.conflicts.map(\.path), [detach.path])
        XCTAssertTrue(TaskHierarchy(tasks: blocked.tasks.map(\.task)).issues.isEmpty)
        XCTAssertTrue(blocked.relationshipBlocks.contains { $0.code == "parent_cycle" })
        let calls = await f.gitHub.calls()
        XCTAssertEqual(calls.commits.flatMap(\.changes).map(\.path), [safe.path])
        _ = try await f.service.keepLocalConflict(selection: f.selection, path: detach.path)
        _ = try await f.engine.sync(selection: f.selection)
        let branch = await f.gitHub.branch()
        XCTAssertNil(try f.task(1, in: branch).parentID)
        XCTAssertEqual(try f.task(2, in: branch).parentID, try f.id(1))
    }

    func testRemoteOrphanIsVisibleWhileIndependentPendingWorkSyncs() async throws {
        let f = try SubtaskSyncFixture(parents: [1: 99])
        let initial = try await f.engine.initialPull(selection: f.selection)
        XCTAssertEqual(initial.tasks.first?.task.parentID, try f.id(99))
        XCTAssertTrue(initial.relationshipBlocks.contains { $0.code == "missing_parent_reference" })
        let safe = try f.pending(3, name: "Independent")
        try await f.install(initial, pending: [safe])
        let report = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(report.pushedCount, 1)
        let durable = try await f.workspace()
        XCTAssertEqual(durable.tasks.first?.task.parentID, try f.id(99))
        XCTAssertTrue(durable.relationshipBlocks.contains { $0.code == "missing_parent_reference" })
    }

    func testCASRetryReevaluatesNewRemoteCycleRatherThanPublishingOldSafeSubset() async throws {
        let f = try SubtaskSyncFixture()
        let initial = try await f.engine.initialPull(selection: f.selection)
        let pending = try f.pending(1, parent: 2)
        try await f.install(initial, pending: [pending])
        await f.gitHub.raceNextUpdate(to: try f.snapshot(head: "raced", parents: [2: 1]))
        let report = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(report.pushedCount, 0)
        let calls = await f.gitHub.calls()
        XCTAssertEqual(calls.commits.count, 1)
        let durable = try await f.workspace()
        XCTAssertEqual(durable.pendingChanges, [pending])
        XCTAssertTrue(durable.relationshipBlocks.contains { $0.code == "parent_cycle" })
        let branch = await f.gitHub.branch()
        XCTAssertNil(try f.task(1, in: branch).parentID)
    }

    func testInflightCoalescedParentEditRetainsIdentityAndRebasesRawBytes() async throws {
        let f = try SubtaskSyncFixture()
        let initial = try await f.engine.initialPull(selection: f.selection)
        let first = try f.pending(1, name: "First")
        try await f.install(initial, pending: [first])
        await f.gitHub.onNextCommit {
            let current = try await f.workspace()
            let task = try XCTUnwrap(current.tasks.first { $0.task.id == (try? f.id(1)) }?.task)
            var update = TaskUpdate(task: task)
            update.name = "Coalesced child"
            update.parentID = try f.id(2)
            _ = try await f.service.editTask(selection: f.selection, id: task.id, expectedTask: task, update: update)
        }
        _ = try await f.engine.sync(selection: f.selection)
        let coalesced = try await f.workspace()
        XCTAssertEqual(coalesced.pendingChanges.count, 1)
        XCTAssertEqual(coalesced.pendingChanges[0].id, first.id)
        XCTAssertEqual(coalesced.pendingChanges[0].createdAt, first.createdAt)
        XCTAssertNotEqual(coalesced.pendingChanges[0].baseBlobSHA, first.baseBlobSHA)
        XCTAssertTrue(try XCTUnwrap(coalesced.pendingChanges[0].content).contains("parent: \"\(try f.id(2).rawValue)\""))
        _ = try await f.engine.sync(selection: f.selection)
        let branch = await f.gitHub.branch()
        XCTAssertEqual(try f.task(1, in: branch).parentID, try f.id(2))
    }

    func testSchemaTransitionRetainsPendingLegacyParentInsteadOfPromotingAndDowngradeFails() async throws {
        let f = try SubtaskSyncFixture(schema: 1)
        let initial = try await f.engine.initialPull(selection: f.selection)
        let content = SubtaskSyncFixture.record(1, parent: 2, name: "Legacy metadata")
        let pending = try PendingChange(id: UUID(), path: f.path(1), baseBlobSHA: "b1", content: content, createdAt: Date(timeIntervalSince1970: 100))
        try await f.install(initial, pending: [pending])
        await f.gitHub.replace(try f.snapshot(head: "upgraded", schema: 2))
        _ = try await f.engine.sync(selection: f.selection)
        let blocked = try await f.workspace()
        XCTAssertEqual(blocked.configuration.schemaVersion, 1)
        XCTAssertEqual(blocked.pendingChanges, [pending])
        XCTAssertNil(blocked.tasks.first?.task.parentID)
        XCTAssertNotNil(blocked.tasks.first?.task.extraProperties.first { $0.name == "parent" })
        XCTAssertEqual(blocked.relationshipBlocks.map(\.code), ["unsupported_schema"])

        let other = try SubtaskSyncFixture()
        let before = try await other.engine.initialPull(selection: other.selection)
        await other.gitHub.replace(try other.snapshot(head: "downgraded", schema: 1))
        do {
            _ = try await other.engine.sync(selection: other.selection)
            XCTFail("Downgrade must fail closed")
        } catch let OTodoError.validation(field, _) { XCTAssertEqual(field, "schema_version") }
        let retained = try await other.workspace()
        XCTAssertEqual(retained, before)
    }
}

private struct SubtaskSyncFixture: Sendable {
    let selection: RepositorySelection
    let store: MemoryWorkspaceStore
    let gitHub: StatefulGitHub
    let engine: SyncEngine
    let service: TaskWorkspaceService

    init(parents: [Int: Int] = [:], schema: Int = 2) throws {
        selection = try RepositorySelection(owner: "o", name: "subtasks", branch: "main", storePath: "")
        store = MemoryWorkspaceStore()
        gitHub = StatefulGitHub(try Self.makeSnapshot(head: "initial", parents: parents, names: [:], schema: schema))
        engine = SyncEngine(gitHub: gitHub, persistence: store, configCodec: StrictStoreConfigCodec(), taskCodec: ObsidianTaskCodec())
        service = TaskWorkspaceService(persistence: store, taskCodec: ObsidianTaskCodec())
    }

    func id(_ number: Int) throws -> TaskID { try TaskID(rawValue: String(format: "%026d", number)) }
    func path(_ number: Int) -> String { "Tasks/" + String(format: "%026d", number) + ".md" }

    static func record(_ number: Int, parent: Int? = nil, name: String? = nil) -> String {
        let edge = parent.map { "parent: \"" + String(format: "%026d", $0) + "\"\n" } ?? ""
        return "---\nname: \"\(name ?? "Task \(number)")\"\nstate: open\nprojects: []\ntags: []\n\(edge)---\nNotes \(number)\r\n"
    }

    func pending(_ number: Int, parent: Int? = nil, name: String? = nil, base: String? = "default") throws -> PendingChange {
        try PendingChange(id: UUID(), path: path(number), baseBlobSHA: base == "default" ? "b\(number)" : base,
                          content: Self.record(number, parent: parent, name: name), createdAt: Date(timeIntervalSince1970: 100))
    }

    func snapshot(head: String, parents: [Int: Int] = [:], names: [Int: String] = [:], schema: Int = 2) throws -> GitSnapshot {
        try Self.makeSnapshot(head: head, parents: parents, names: names, schema: schema)
    }

    private static func makeSnapshot(head: String, parents: [Int: Int], names: [Int: String], schema: Int) throws -> GitSnapshot {
        let config = Fixture.config.replacingOccurrences(of: "schema_version = 1", with: "schema_version = \(schema)")
        var files = [
            try RemoteFile(path: ".todo/config.toml", blobSHA: "config", content: config),
        ]
        for number in 1...3 {
            files.append(try RemoteFile(path: "Tasks/" + String(format: "%026d", number) + ".md",
                                        blobSHA: names[number] == nil && parents[number] == nil ? "b\(number)" : "\(head)-b\(number)",
                                        content: record(number, parent: parents[number], name: names[number])))
        }
        return try GitSnapshot(headCommitSHA: head, rootTreeSHA: head + "-tree", files: files)
    }

    func install(_ base: WorkspaceState, pending: [PendingChange], conflicts: [SyncConflict] = []) async throws {
        var tasks = Dictionary(uniqueKeysWithValues: base.tasks.map { ($0.task.relativePath, $0) })
        for change in pending {
            guard let content = change.content else { tasks.removeValue(forKey: change.path); continue }
            let name = String(change.path.split(separator: "/").last!.dropLast(3))
            let task = try ObsidianTaskCodec().parseTask(id: TaskID(rawValue: name), relativePath: change.path,
                                                        text: content, configuration: base.configuration)
            tasks[change.path] = TaskDocument(task: task, content: content, blobSHA: change.baseBlobSHA)
        }
        let workspace = try WorkspaceState(selection: selection, configuration: base.configuration,
                                           knownProjectSlugs: base.knownProjectSlugs,
                                           tasks: tasks.values.sorted { $0.task.id < $1.task.id },
                                           baseHeadCommitSHA: base.baseHeadCommitSHA, baseRootTreeSHA: base.baseRootTreeSHA,
                                           pendingChanges: pending, conflicts: conflicts, revision: base.revision + 1)
        try await store.save(workspace, expectedRevision: base.revision)
    }

    func workspace() async throws -> WorkspaceState {
        let value = await store.current()
        return try XCTUnwrap(value)
    }

    func task(_ number: Int, in snapshot: GitSnapshot) throws -> TodoTask {
        let file = try XCTUnwrap(snapshot.files.first { $0.path == path(number) })
        let config = try XCTUnwrap(snapshot.files.first { $0.path == ".todo/config.toml" })
        return try ObsidianTaskCodec().parseTask(id: id(number), relativePath: path(number), text: file.content,
                                                configuration: StrictStoreConfigCodec().parseConfiguration(config.content))
    }
}

extension SyncEngineTests {
    func testLaterTaskWaitsForWithheldArchiveDestinationThenPublishesAfterResolution() async throws {
        let f = try Fixture(twoTasks: true)
        _ = try await f.engine.initialPull(selection: f.selection)
        let service = TaskWorkspaceService(persistence: f.store, taskCodec: ObsidianTaskCodec())
        let archived = try await service.archiveProject(selection: f.selection, slug: "alpha",
            destination: .newProject(slug: "beta", name: "Beta"))
        let later = try PendingChange(id: UUID(), path: f.bPath, baseBlobSHA: "b1",
            content: Fixture.record("Later task", projects: ["beta"], body: "Needs the destination\n"),
            createdAt: Date(timeIntervalSince1970: 100))
        try await f.store.save(try f.applying(archived, pending: archived.pendingChanges + [later]),
                               expectedRevision: archived.revision)
        let divergent = try f.snapshot(head: "diverged", tree: "diverged-tree",
            a: Fixture.record("Remote A", projects: ["alpha"], body: "Remote notes\n"),
            b: f.bOriginal, aSHA: "remote-a")
        await f.gitHub.replace(divergent)
        let report = try await f.engine.sync(selection: f.selection)
        let blockedRemote = await f.gitHub.branch()
        XCTAssertEqual(report.pushedCount, 0)
        XCTAssertEqual(blockedRemote.files.first { $0.path == f.bPath }?.content, f.bOriginal,
                       "A later task must not publish a link to the withheld destination")
        XCTAssertNil(blockedRemote.files.first { $0.path == f.path("Projects/beta.md") })

        _ = try await service.resolveConflict(selection: f.selection, path: f.aPath, resolution: .keepLocal)
        _ = try await f.engine.sync(selection: f.selection)
        let published = await f.gitHub.branch()
        XCTAssertNotNil(published.files.first { $0.path == f.path("Projects/beta.md") })
        XCTAssertEqual(published.files.first { $0.path == f.bPath }?.content, later.content)
    }

    func testMovedProjectConflictResolvesAtCurrentDirectoryWithRemoteEvidence() async throws {
        for keepLocal in [true, false] {
            let f = try Fixture()
            let slug = "00000000000000000000000000"
            let oldPath = f.path("Projects/\(slug).md")
            let newPath = f.path("Areas/\(slug).md")
            let initial = await f.gitHub.branch()
            let files = try initial.files.filter { !$0.path.contains("/Tasks/") }.map { file in
                file.path == f.path("Projects/alpha.md")
                    ? try RemoteFile(path: oldPath, blobSHA: file.blobSHA, content: file.content) : file
            }
            await f.gitHub.replace(try GitSnapshot(headCommitSHA: "projects", rootTreeSHA: "projects-tree", files: files))
            _ = try await f.engine.initialPull(selection: f.selection)
            let service = TaskWorkspaceService(persistence: f.store, taskCodec: ObsidianTaskCodec())
            _ = try await service.archiveProject(selection: f.selection, slug: slug)

            let movedContent = "---\nname: Remote title\nplugin: changed\n---\nRemote notes\n"
            let moved = try GitSnapshot(headCommitSHA: "moved", rootTreeSHA: "moved-tree", files: [
                try RemoteFile(path: f.path(".todo/config.toml"), blobSHA: "moved-config",
                    content: Fixture.config.replacingOccurrences(of: "projects_directory = \"Projects\"", with: "projects_directory = \"Areas\"")),
                try RemoteFile(path: newPath, blobSHA: "moved-project", content: movedContent),
            ])
            await f.gitHub.replace(moved)
            let report = try await f.engine.sync(selection: f.selection)
            let conflict = try XCTUnwrap(report.conflicts.first)
            XCTAssertEqual(conflict.path, newPath)
            XCTAssertEqual(conflict.remoteContent, movedContent)
            XCTAssertEqual(conflict.remoteBlobSHA, "moved-project")
            let resolved = try await service.resolveConflict(
                selection: f.selection, path: conflict.path, resolution: keepLocal ? .keepLocal : .useRemote
            )
            XCTAssertFalse(resolved.pendingChanges.contains { $0.path == oldPath })
            XCTAssertTrue(resolved.conflicts.isEmpty)
            XCTAssertEqual(resolved.projects.first?.project.relativePath, "Areas/\(slug).md")
            _ = try await f.engine.sync(selection: f.selection)
            let remote = await f.gitHub.branch()
            XCTAssertFalse(remote.files.contains { $0.path == oldPath })
            let saved = try XCTUnwrap(remote.files.first { $0.path == newPath })
            let project = try ObsidianProjectCodec().parseProject(slug: slug, relativePath: "Areas/\(slug).md", text: saved.content)
            XCTAssertEqual(project.isArchived, keepLocal)
            XCTAssertEqual(project.body, keepLocal ? "# Alpha\n" : "Remote notes\n")
            if !keepLocal { XCTAssertEqual(saved.content, movedContent) }
        }
    }

    func testArchiveGroupWithholdsProjectAndTasksOnEitherConflictButPublishesIndependentEdit() async throws {
        for conflictOnProject in [false, true] {
            let f = try Fixture(twoTasks: true)
            _ = try await f.engine.initialPull(selection: f.selection)
            let service = TaskWorkspaceService(persistence: f.store, taskCodec: ObsidianTaskCodec())
            let beforeEdit = try await service.archiveProject(selection: f.selection, slug: "alpha", destination: .inbox)
            let archived = try await service.updateProject(
                selection: f.selection, expectedProject: XCTUnwrap(beforeEdit.projects.first).project,
                title: "Renamed Alpha", body: "Edited after archiving.\n"
            )
            let independent = try PendingChange(id: UUID(), path: f.bPath, baseBlobSHA: "b1",
                content: Fixture.record("Independent local", body: "Independent\n"), createdAt: Date(timeIntervalSince1970: 100))
            try await f.store.save(try f.applying(archived, pending: archived.pendingChanges + [independent]),
                                   expectedRevision: archived.revision)
            let projectPath = f.path("Projects/alpha.md")
            let conflictingPath = conflictOnProject ? projectPath : f.aPath
            let remoteContent = conflictOnProject ? "---\nname: Alpha remote\nplugin: [true, 2]\n---\nRemote notes\r\n"
                : Fixture.record("A remote", projects: ["alpha"], body: "Remote task\n")
            let oldRemote = await f.gitHub.branch()
            let divergent = try GitSnapshot(headCommitSHA: "diverged", rootTreeSHA: "diverged-tree",
                files: oldRemote.files.map { file in
                    file.path == conflictingPath ? try RemoteFile(path: file.path, blobSHA: "divergent-blob", content: remoteContent) : file
                })
            await f.gitHub.replace(divergent)

            let report = try await f.engine.sync(selection: f.selection)
            let remote = await f.gitHub.branch()
            XCTAssertEqual(report.pushedCount, 1)
            XCTAssertEqual(report.conflicts.map(\.path), [conflictingPath])
            XCTAssertEqual(remote.files.first { $0.path == f.bPath }?.content, independent.content)
            for path in [projectPath, f.aPath] {
                XCTAssertEqual(remote.files.first { $0.path == path }, divergent.files.first { $0.path == path })
            }
            let savedValue = await f.store.current()
            let saved = try XCTUnwrap(savedValue)
            XCTAssertEqual(Set(saved.pendingChanges.map(\.path)), Set([projectPath, f.aPath]))
            XCTAssertEqual(saved.projects.first?.content, archived.projects.first?.content)
            XCTAssertEqual(saved.projects.first?.blobSHA, "project")
            XCTAssertTrue(try XCTUnwrap(saved.projects.first).project.isArchived)
            XCTAssertEqual(saved.projects.first?.project.name, "Renamed Alpha")
            XCTAssertEqual(saved.projects.first?.project.body, "Edited after archiving.\n")
            let conflict = try XCTUnwrap(saved.conflicts.first)
            XCTAssertEqual(conflict.remoteContent, remoteContent)
            XCTAssertEqual(conflict.remoteBlobSHA, "divergent-blob")
        }
    }

    func testOverlappingArchiveGroupsStayTogetherAfterSecondArchiveAndRemoteConflict() async throws {
        let f = try Fixture(twoTasks: true)
        _ = try await f.engine.initialPull(selection: f.selection)
        let service = TaskWorkspaceService(persistence: f.store, taskCodec: ObsidianTaskCodec())
        _ = try await service.archiveProject(selection: f.selection, slug: "alpha",
                                              destination: .newProject(slug: "beta", name: "Beta"))
        let coalesced = try await service.archiveProject(selection: f.selection, slug: "beta", destination: .inbox)
        let independent = try PendingChange(id: UUID(), path: f.bPath, baseBlobSHA: "b1",
            content: Fixture.record("Independent", body: "Unrelated\n"), createdAt: Date(timeIntervalSince1970: 100))
        try await f.store.save(try f.applying(coalesced, pending: coalesced.pendingChanges + [independent]),
                               expectedRevision: coalesced.revision)
        let oldRemote = await f.gitHub.branch()
        let divergent = try GitSnapshot(headCommitSHA: "diverged", rootTreeSHA: "diverged-tree",
            files: oldRemote.files.map { file in
                file.path == f.path("Projects/alpha.md")
                    ? try RemoteFile(path: file.path, blobSHA: "remote-alpha", content: "# Alpha remote\n") : file
            })
        await f.gitHub.replace(divergent)

        let report = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(report.pushedCount, 1)
        let remote = await f.gitHub.branch()
        XCTAssertNil(remote.files.first { $0.path == f.path("Projects/beta.md") })
        XCTAssertEqual(remote.files.first { $0.path == f.aPath }?.content, f.aOriginal)
        XCTAssertEqual(remote.files.first { $0.path == f.path("Projects/alpha.md") }?.content, "# Alpha remote\n")
        XCTAssertEqual(remote.files.first { $0.path == f.bPath }?.content, independent.content)
        let savedValue = await f.store.current()
        let saved = try XCTUnwrap(savedValue)
        XCTAssertEqual(Set(saved.pendingChanges.map(\.path)), Set([f.aPath, f.path("Projects/alpha.md"), f.path("Projects/beta.md")]))
        XCTAssertTrue(saved.projects.allSatisfy(\.project.isArchived))
    }

    func testRacedRefCannotPublishAttemptedSubsetOfExpandedArchiveGroup() async throws {
        let f = try Fixture(twoTasks: true)
        _ = try await f.engine.initialPull(selection: f.selection)
        let service = TaskWorkspaceService(persistence: f.store, taskCodec: ObsidianTaskCodec())
        _ = try await service.archiveProject(selection: f.selection, slug: "alpha",
                                              destination: .newProject(slug: "beta", name: "Beta"))
        let race = try f.snapshot(head: "race", tree: "race-tree", a: f.aOriginal,
                                  b: Fixture.record("B raced", body: "Unrelated remote\n"), bSHA: "b-race")
        await f.gitHub.raceNextUpdate(to: race)
        await f.gitHub.onNextCommit {
            _ = try await service.archiveProject(selection: f.selection, slug: "beta",
                                                  destination: .newProject(slug: "gamma", name: "Gamma"))
        }
        let report = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(report.pushedCount, 0)
        let unchanged = await f.gitHub.branch()
        XCTAssertEqual(unchanged, race)
        let savedValue = await f.store.current()
        let saved = try XCTUnwrap(savedValue)
        XCTAssertEqual(Set(saved.pendingChanges.map(\.path)),
                       Set([f.aPath, f.path("Projects/alpha.md"), f.path("Projects/beta.md"), f.path("Projects/gamma.md")]))

        let retried = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(retried.pushedCount, 4)
        let remote = await f.gitHub.branch()
        let task = try XCTUnwrap(remote.files.first { $0.path == f.aPath })
        XCTAssertTrue(task.content.contains("[[Vault/Projects/gamma]]"))
        for slug in ["alpha", "beta", "gamma"] {
            let file = try XCTUnwrap(remote.files.first { $0.path == f.path("Projects/\(slug).md") })
            let project = try ObsidianProjectCodec().parseProject(slug: slug, relativePath: "Projects/\(slug).md", text: file.content)
            XCTAssertEqual(project.isArchived, slug != "gamma")
        }
    }

    func testConfirmedCoalescedArchiveRebasesWithoutDetachingRemainingGroup() async throws {
        let f = try Fixture()
        _ = try await f.engine.initialPull(selection: f.selection)
        let service = TaskWorkspaceService(persistence: f.store, taskCodec: ObsidianTaskCodec())
        _ = try await service.archiveProject(selection: f.selection, slug: "alpha",
                                              destination: .newProject(slug: "beta", name: "Beta"))
        await f.gitHub.onNextCommit {
            _ = try await service.archiveProject(selection: f.selection, slug: "beta", destination: .inbox)
        }
        _ = try await f.engine.sync(selection: f.selection)
        let firstRemote = await f.gitHub.branch()
        let betaPath = f.path("Projects/beta.md")
        let activeBeta = try XCTUnwrap(firstRemote.files.first { $0.path == betaPath })
        XCTAssertFalse(try ObsidianProjectCodec().parseProject(slug: "beta", relativePath: "Projects/beta.md", text: activeBeta.content).isArchived)
        let savedValue = await f.store.current()
        let saved = try XCTUnwrap(savedValue)
        XCTAssertEqual(Set(saved.pendingChanges.map(\.path)), Set([f.aPath, betaPath]))
        XCTAssertEqual(saved.projects.first { $0.project.slug == "beta" }?.blobSHA, activeBeta.blobSHA)
        let divergent = try GitSnapshot(headCommitSHA: "diverged", rootTreeSHA: "diverged-tree",
            files: firstRemote.files.map { file in
                file.path == f.aPath ? try RemoteFile(path: file.path, blobSHA: "remote-task",
                    content: Fixture.record("Remote edited", projects: ["beta"], body: "Remote\n")) : file
            })
        await f.gitHub.replace(divergent)

        let report = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(report.pushedCount, 0)
        XCTAssertEqual(report.conflicts.map(\.path), [f.aPath])
        let blocked = await f.gitHub.branch()
        XCTAssertEqual(blocked, divergent)
    }

    func testHierarchyFilteringAlsoWithholdsGroupedProjectCreation() async throws {
        let f = try SubtaskSyncFixture()
        let initial = try await f.engine.initialPull(selection: f.selection)
        let group = UUID()
        let brokenTask = try PendingChange(id: UUID(), path: f.path(1), baseBlobSHA: "b1",
            content: SubtaskSyncFixture.record(1, parent: 99), createdAt: Date(timeIntervalSince1970: 100), groupID: group)
        let projectContent = "---\nname: New project\n---\n"
        let project = try ObsidianProjectCodec().parseProject(slug: "new", relativePath: "Projects/new.md", text: projectContent)
        let projectChange = try PendingChange(id: UUID(), path: project.relativePath, baseBlobSHA: nil,
            content: projectContent, createdAt: Date(timeIntervalSince1970: 100), groupID: group)
        let independent = try f.pending(3, name: "Independent")
        let broken = try ObsidianTaskCodec().parseTask(id: f.id(1), relativePath: f.path(1),
            text: XCTUnwrap(brokenTask.content), configuration: initial.configuration)
        let workspace = try WorkspaceState(selection: f.selection, configuration: initial.configuration,
            knownProjectSlugs: ["new"], tasks: initial.tasks.map {
                $0.task.id == broken.id ? TaskDocument(task: broken, content: brokenTask.content!, blobSHA: "b1") : $0
            }, baseHeadCommitSHA: initial.baseHeadCommitSHA, baseRootTreeSHA: initial.baseRootTreeSHA,
            pendingChanges: [brokenTask, projectChange, independent], conflicts: [], revision: initial.revision + 1,
            projects: [ProjectDocument(project: project, content: projectContent, blobSHA: nil)])
        try await f.store.save(workspace, expectedRevision: initial.revision)

        let report = try await f.engine.sync(selection: f.selection)
        XCTAssertEqual(report.pushedCount, 1)
        let remote = await f.gitHub.branch()
        XCTAssertNil(remote.files.first { $0.path == project.relativePath })
        XCTAssertNil(try f.task(1, in: remote).parentID)
        XCTAssertEqual(try f.task(3, in: remote).name, "Independent")
    }
}

private extension Fixture {
    func applying(_ base: WorkspaceState, pending: [PendingChange]) throws -> WorkspaceState {
        var tasks = Dictionary(uniqueKeysWithValues: base.tasks.map { ($0.task.relativePath, $0) })
        for change in pending where change.path.hasPrefix(path("Tasks/")) {
            let relativePath = String(change.path.dropFirst(selection.storePath.count + 1))
            guard let content = change.content else { tasks.removeValue(forKey: relativePath); continue }
            let id = try TaskID(rawValue: String(relativePath.split(separator: "/").last!.dropLast(3)))
            let task = try ObsidianTaskCodec().parseTask(id: id, relativePath: relativePath, text: content, configuration: base.configuration)
            tasks[relativePath] = TaskDocument(task: task, content: content, blobSHA: change.baseBlobSHA)
        }
        return try WorkspaceState(selection: selection, configuration: base.configuration,
            knownProjectSlugs: base.knownProjectSlugs, tasks: tasks.values.sorted { $0.task.relativePath < $1.task.relativePath },
            baseHeadCommitSHA: base.baseHeadCommitSHA, baseRootTreeSHA: base.baseRootTreeSHA,
            pendingChanges: pending, conflicts: base.conflicts, revision: base.revision + 1, projects: base.projects)
    }
}
