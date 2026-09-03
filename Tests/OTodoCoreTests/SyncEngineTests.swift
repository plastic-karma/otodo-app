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

    func edit(_ base: WorkspaceState, pending: PendingChange, revision: UInt64? = nil) throws -> WorkspaceState {
        var tasks = base.tasks
        let index = try XCTUnwrap(tasks.firstIndex { $0.task.relativePath == Self.aRelative })
        let task = try ObsidianTaskCodec().parseTask(id: tasks[index].task.id, relativePath: Self.aRelative, text: pending.content, configuration: base.configuration)
        tasks[index] = TaskDocument(task: task, content: pending.content, blobSHA: pending.baseBlobSHA)
        return try WorkspaceState(selection: selection, configuration: base.configuration, knownProjectSlugs: base.knownProjectSlugs, tasks: tasks, baseHeadCommitSHA: base.baseHeadCommitSHA, baseRootTreeSHA: base.baseRootTreeSHA, pendingChanges: [pending], conflicts: [], revision: revision ?? base.revision + 1)
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
