import Foundation
import XCTest
@testable import OTodoCore

final class SubtaskTests: XCTestCase, @unchecked Sendable {
    private struct Corpus: Decodable {
        let record_cases: [Record]
        let graph_cases: [Graph]
        struct Record: Decodable {
            let name: String
            let schema_version: Int
            let id: TaskID
            let markdown: String
            let expected_parent: TaskID?
            let expected_error: String?
        }
        struct Graph: Decodable {
            let name: String
            let tasks: [Edge]
            let expected_issues: [Issue]
        }
        struct Edge: Decodable { let id: TaskID; let parent: TaskID? }
        struct Issue: Decodable, Equatable { let code: String; let task_id: TaskID }
    }

    func testSharedRecordAndGraphCorpus() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "subtasks", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        let codec = ObsidianTaskCodec()
        for record in corpus.record_cases {
            let config = try configuration(record.schema_version)
            let path = "Tasks/\(record.id.rawValue).md"
            if let expectedError = record.expected_error {
                XCTAssertThrowsError(try codec.parseTask(id: record.id, relativePath: path, text: record.markdown, configuration: config), record.name) { error in
                    guard case let OTodoError.validation(field, message) = error else { return XCTFail("\(error)") }
                    XCTAssertEqual(field, "parent")
                    XCTAssertTrue(message.contains(expectedError))
                }
                continue
            }
            let task = try codec.parseTask(id: record.id, relativePath: path, text: record.markdown, configuration: config)
            XCTAssertEqual(task.parentID, record.expected_parent, record.name)
            let output = try codec.serializeTask(task, configuration: config)
            let roundTrip = try codec.parseTask(id: record.id, relativePath: path, text: output, configuration: config)
            XCTAssertEqual(roundTrip, task, record.name)
            XCTAssertEqual(Array(roundTrip.body.utf8), Array(task.body.utf8), record.name)
            XCTAssertEqual(try JSONDecoder().decode(TodoTask.self, from: JSONEncoder().encode(task)), task, record.name)
            if let parent = task.parentID {
                XCTAssertTrue(output.contains("parent: \"\(parent.rawValue)\"\n"), record.name)
            }
            if record.schema_version == 1 {
                XCTAssertNotNil(task.extraProperties.first { $0.name == "parent" }, record.name)
            }
        }
        for graph in corpus.graph_cases {
            let tasks = try graph.tasks.enumerated().map { index, edge in
                try task(edge.id, parent: edge.parent, path: "Tasks/\(index)/\(edge.id.rawValue).md")
            }
            let issues = TaskHierarchy(tasks: tasks).issues.map { Corpus.Issue(code: $0.code, task_id: $0.taskID) }
            XCTAssertEqual(issues, graph.expected_issues, graph.name)
        }
    }

    func testMatchedOnlyProjectionAndDeepIterativeTraversal() throws {
        let a = try task(id(1))
        let b = try task(id(2), parent: a.id)
        let c = try task(id(3), parent: b.id)
        let h = TaskHierarchy(tasks: [c, b, a])
        XCTAssertEqual(h.rows(matching: [c, a]).map(\.task.id), [c.id, a.id])
        XCTAssertEqual(h.rows(matching: [c, a]).map(\.depth), [0, 0])
        XCTAssertEqual(h.rows(matching: [c, b, a]).map(\.task.id), [a.id, b.id, c.id])
        XCTAssertEqual(h.ancestorIDs(of: c.id), [a.id, b.id])
        let deep = try (1...10_000).map { try task(id($0), parent: $0 == 1 ? nil : id($0 - 1)) }
        let hierarchy = TaskHierarchy(tasks: deep)
        XCTAssertTrue(hierarchy.issues.isEmpty)
        XCTAssertEqual(hierarchy.descendantIDs(of: deep[0].id).count, 9_999)
        XCTAssertEqual(hierarchy.rows(matching: Array(deep.reversed())).last?.depth, 9_999)
    }

    func testFreshMutationChecksNonleafAndExplicitRepairWithoutCascades() async throws {
        let parent = try task(id(1), state: "done")
        let child = try task(id(2), parent: parent.id, state: "done")
        let broken = try task(id(3), parent: id(99))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, service, selection) = try await seed([parent, child, broken], at: directory)
        do {
            try await service.deleteTask(selection: selection, id: parent.id, expectedTask: parent)
            XCTFail("Nonleaf deletion must refuse terminal children")
        } catch let OTodoError.validation(field, message) {
            XCTAssertEqual(field, "parent")
            XCTAssertTrue(message.contains("task_in_use"))
            XCTAssertTrue(message.contains(child.id.rawValue))
        }
        var cycle = TaskUpdate(task: parent)
        cycle.parentID = child.id
        do {
            _ = try await service.editTask(selection: selection, id: parent.id, expectedTask: parent, update: cycle)
            XCTFail("Cycle must fail")
        } catch let OTodoError.validation(_, message) { XCTAssertTrue(message.contains("parent_cycle")) }
        var repair = TaskUpdate(task: broken)
        repair.parentID = nil
        let repaired = try await service.editTask(selection: selection, id: broken.id, expectedTask: broken, update: repair)
        XCTAssertNil(repaired.parentID)
        var detach = TaskUpdate(task: child)
        detach.parentID = nil
        _ = try await service.editTask(selection: selection, id: child.id, expectedTask: child, update: detach)
        try await service.deleteTask(selection: selection, id: parent.id, expectedTask: parent)
        let saved = try await service.loadWorkspace(selection: selection)
        XCTAssertEqual(Set(saved.tasks.map(\.task.id)), [child.id, broken.id])
        XCTAssertTrue(saved.relationshipBlocks.isEmpty)
        let disk = try await store.load(selection: selection)
        XCTAssertEqual(disk, saved)
    }

    func testRecurrenceStateExplicitEditAndBatchReschedulePreserveParent() async throws {
        let parent = try task(id(1), state: "done")
        var child = try task(id(2), parent: parent.id)
        child.dueDate = try CivilDate(rawValue: "2026-09-06")
        child.recurrence = "FREQ=DAILY"
        child.recurrenceFrom = .schedule
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, service, selection) = try await seed([parent, child], at: directory)
        let completed = try await service.completeTask(selection: selection, expectedTask: child, completedOn: CivilDate(rawValue: "2026-09-06"))
        XCTAssertEqual(completed.parentID, parent.id)
        XCTAssertEqual(completed.dueDate?.rawValue, "2026-09-07")
        let edited = try await service.editTask(selection: selection, id: child.id, expectedTask: completed,
                                                name: "Renamed", state: "done", projectSlugs: [], tags: [],
                                                dueDate: completed.dueDate, recurrence: completed.recurrence,
                                                recurrenceFrom: completed.recurrenceFrom, body: child.body)
        XCTAssertEqual(edited.parentID, parent.id)
        let rescheduled = try await service.rescheduleTasks(selection: selection, expectedTasks: [edited],
                                                            dueDate: .set(CivilDate(rawValue: "2026-09-10")), dueTime: .preserve)
        XCTAssertEqual(rescheduled[0].parentID, parent.id)
        let saved = try await service.loadWorkspace(selection: selection)
        XCTAssertEqual(saved.tasks.first { $0.task.id == parent.id }?.task, parent)
        XCTAssertEqual(saved.pendingChanges.count, 1)
        XCTAssertEqual(saved.pendingChanges[0].baseBlobSHA, "blob-\(child.id.rawValue)")
    }

    func testStaleParentPickerIsRevalidatedAndGlobalCaptureRemainsRoot() async throws {
        let parent = try task(id(1))
        let child = try task(id(2))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, service, selection) = try await seed([parent, child], at: directory)
        try await service.deleteTask(selection: selection, id: parent.id, expectedTask: parent)
        var update = TaskUpdate(task: child)
        update.parentID = parent.id
        do {
            _ = try await service.editTask(selection: selection, id: child.id, expectedTask: child, update: update)
            XCTFail("Deleted destination must not be accepted")
        } catch let OTodoError.notFound(resource) { XCTAssertTrue(resource.contains(parent.id.rawValue)) }
        let capture = try await service.addTask(selection: selection, name: "Shared capture", body: "URL")
        XCTAssertNil(capture.parentID)
    }

    func testGenuineEnvelopeOneImportsLegacyParentWithoutChangingEvidenceAndCASWritesTwo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let selection = try selection()
        let taskID = try id(1)
        // This is the historical encoded shape, not a version-2 task encoded with a changed marker.
        let raw = "---\nname: Legacy\nstate: open\nprojects: []\ntags: []\nparent: null\n---\nNotes\r\nwithout newline"
        let encoder = JSONEncoder()
        let configJSON = try JSONSerialization.jsonObject(with: encoder.encode(configuration(1)))
        let selectionJSON = try JSONSerialization.jsonObject(with: encoder.encode(selection))
        let extraJSON = try JSONSerialization.jsonObject(with: encoder.encode([YAMLProperty(name: "parent", value: .null)]))
        let uuid = "11111111-1111-1111-1111-111111111111"
        let path = "Tasks/\(taskID.rawValue).md"
        let oldTask: [String: Any] = ["id": taskID.rawValue, "relativePath": path, "name": "Legacy", "state": "open",
                                    "projectSlugs": [], "tags": [], "body": "Notes\r\nwithout newline", "extraProperties": extraJSON]
        let old: [String: Any] = ["version": 1, "workspace": [
            "selection": selectionJSON, "configuration": configJSON, "knownProjectSlugs": [],
            "tasks": [["task": oldTask, "content": raw, "blobSHA": "base"]],
            "baseHeadCommitSHA": "head", "baseRootTreeSHA": "tree", "revision": 7,
            "pendingChanges": [
                ["id": uuid, "path": path, "baseBlobSHA": "base", "content": raw, "createdAt": Date(timeIntervalSince1970: 1_788_652_800).timeIntervalSinceReferenceDate],
                ["id": "22222222-2222-2222-2222-222222222222", "path": "Tasks/deleted.md", "baseBlobSHA": "deleted-base", "createdAt": 42],
            ],
            "conflicts": [
                ["path": path, "baseBlobSHA": "base", "remoteBlobSHA": "remote", "localContent": raw, "remoteContent": "remote raw\r\n"],
                ["path": "Tasks/deleted.md", "baseBlobSHA": "deleted-base", "remoteBlobSHA": "deleted-remote", "remoteContent": "Deleted record remote bytes"],
            ]
        ]]
        let bytes = try JSONSerialization.data(withJSONObject: old, options: [.sortedKeys])
        let url = directory.appendingPathComponent(FileWorkspaceStore.selectionKey(for: selection) + ".json")
        try bytes.write(to: url)
        let store = FileWorkspaceStore(rootURL: directory)
        let loadedValue = try await store.load(selection: selection)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNil(loaded.tasks[0].task.parentID)
        XCTAssertEqual(loaded.tasks[0].task.extraProperties, [YAMLProperty(name: "parent", value: .null)])
        let next = try WorkspaceState(selection: selection, configuration: loaded.configuration, tasks: loaded.tasks,
                                      baseHeadCommitSHA: loaded.baseHeadCommitSHA, baseRootTreeSHA: loaded.baseRootTreeSHA,
                                      pendingChanges: loaded.pendingChanges, conflicts: loaded.conflicts, revision: 8)
        try await store.save(next, expectedRevision: 7)
        let reloaded = try await store.load(selection: selection)
        XCTAssertEqual(reloaded, next)
        XCTAssertEqual(next.pendingChanges[0].id.uuidString, uuid)
        XCTAssertEqual(next.tasks[0].content, raw)
        XCTAssertEqual(next.conflicts[0].remoteContent, "remote raw\r\n")
        XCTAssertNil(next.pendingChanges[1].content)
        XCTAssertEqual(next.pendingChanges[1].baseBlobSHA, "deleted-base")
        XCTAssertNil(next.conflicts[1].localContent)
        XCTAssertEqual(next.conflicts[1].remoteContent, "Deleted record remote bytes")
        let newJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(newJSON["version"] as? Int, 2)
    }

    func testSchemaContextKeepsLegacyMetadataAndRejectsConflictingTypedParent() throws {
        let codec = ObsidianTaskCodec()
        var legacy = try task(id(1))
        legacy.extraProperties = [YAMLProperty(name: "parent", value: .sequence([.null, .string("plugin")]))]
        let text = try codec.serializeTask(legacy, configuration: configuration(1))
        XCTAssertEqual(try codec.parseTask(id: legacy.id, relativePath: legacy.relativePath, text: text,
                                           configuration: configuration(1)).extraProperties, legacy.extraProperties)
        legacy.parentID = try id(2)
        XCTAssertThrowsError(try codec.serializeTask(legacy, configuration: configuration(2)))
        XCTAssertThrowsError(try JSONDecoder().decode(TodoTask.self, from: JSONEncoder().encode(legacy)))
        var child = try task(id(1), parent: id(2))
        child.dueDate = try CivilDate(rawValue: "2026-09-06")
        child.dueTime = try CivilTime(rawValue: "14:35")
        XCTAssertThrowsError(try codec.serializeTask(child, configuration: configuration(1)))
        let v2 = try codec.serializeTask(child, configuration: configuration(2))
        XCTAssertEqual(try codec.parseTask(id: child.id, relativePath: child.relativePath, text: v2,
                                          configuration: configuration(2)), child)
    }

    func testLegacyShapedSchemaTwoCacheReconcilesOnlyAgainstRawParent() throws {
        let child = try task(id(1), parent: id(2))
        let configuration = try configuration()
        let raw = try ObsidianTaskCodec().serializeTask(child, configuration: configuration)
        var oldTask = child
        oldTask.parentID = nil
        oldTask.extraProperties = [YAMLProperty(name: "parent", value: .string(try id(2).rawValue.lowercased()))]
        let old = try WorkspaceState(
            selection: selection(), configuration: configuration,
            tasks: [TaskDocument(task: oldTask, content: raw, blobSHA: "base")],
            baseHeadCommitSHA: "head", baseRootTreeSHA: "tree", pendingChanges: [], conflicts: [], revision: 19
        )
        let imported = try old.importCacheRecords(legacyEnvelope: true)
        XCTAssertEqual(imported.tasks[0].task, child)
        XCTAssertEqual(imported.tasks[0].content, raw)
        XCTAssertEqual(imported.revision, 19)
        XCTAssertThrowsError(try old.importCacheRecords(legacyEnvelope: false))
        var disagreeing = oldTask
        disagreeing.extraProperties = [YAMLProperty(name: "parent", value: .string(try id(3).rawValue))]
        let invalid = try WorkspaceState(
            selection: selection(), configuration: configuration,
            tasks: [TaskDocument(task: disagreeing, content: raw, blobSHA: "base")],
            baseHeadCommitSHA: "head", baseRootTreeSHA: "tree", pendingChanges: [], conflicts: []
        )
        XCTAssertThrowsError(try invalid.importCacheRecords(legacyEnvelope: true))
    }

    func testParentEligibilityIsIndependentAcrossReminderWidgetAndWatch() throws {
        let parent = try task(id(1), state: "done")
        var child = try task(id(2), parent: parent.id)
        child.dueDate = try CivilDate(rawValue: "2026-09-06")
        let states = try configuration().states
        let now = Date(timeIntervalSince1970: 1_788_652_800)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reminders = TaskReminderPlanner.reminders(for: [parent, child], states: states, now: now, calendar: calendar)
        let widget = TodayWidgetSnapshotBuilder.make(tasks: [parent, child], states: states, generatedAt: now)
        var orphan = child
        orphan.parentID = try id(99)
        XCTAssertEqual(reminders, TaskReminderPlanner.reminders(for: [orphan], states: states, now: now, calendar: calendar))
        XCTAssertEqual(widget, TodayWidgetSnapshotBuilder.make(tasks: [orphan], states: states, generatedAt: now))
        XCTAssertEqual(reminders.map(\.taskID), [child.id])
        let watch = WatchWorkspaceSnapshot(snapshot: widget, workspaceAvailable: true)
        XCTAssertEqual(watch.day(on: "2026-09-06").today.map(\.id), [child.id.rawValue])
        XCTAssertEqual(try JSONDecoder().decode(WatchWorkspaceSnapshot.self, from: JSONEncoder().encode(watch)), watch)
        XCTAssertEqual(watch.version, 1)
    }

    func testLegacyOrdinaryEditAndCaptureWorkButRelationOperationsRefuseWithoutDroppingExtras() async throws {
        var legacy = try task(id(1))
        legacy.extraProperties = [YAMLProperty(name: "parent", value: .string("plugin-owned"))]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, service, selection) = try await seed([legacy], at: directory, schema: 1)
        var update = TaskUpdate(task: legacy)
        update.name = "Ordinary edit"
        let edited = try await service.editTask(selection: selection, id: legacy.id, expectedTask: legacy, update: update)
        XCTAssertEqual(edited.extraProperties, legacy.extraProperties)
        XCTAssertNil(edited.parentID)
        do {
            _ = try await service.addTask(selection: selection, name: "Child", parentID: legacy.id)
            XCTFail("Schema one cannot add children")
        } catch let OTodoError.unsupportedSchema(found, supported) {
            XCTAssertEqual(found, 1)
            XCTAssertEqual(supported, 2)
        }
        do {
            _ = try await service.editTask(selection: selection, id: edited.id, expectedTask: edited,
                                           name: edited.name, state: edited.state, projectSlugs: [], tags: [],
                                           dueDate: nil, recurrence: nil, recurrenceFrom: nil, body: edited.body, parent: .clear)
            XCTFail("An explicit relation operation is unsupported even for a flat root")
        } catch let OTodoError.unsupportedSchema(found, _) { XCTAssertEqual(found, 1) }
        let capture = try await service.addTask(selection: selection, name: "Inbox capture")
        XCTAssertNil(capture.parentID)
        let saved = try await service.loadWorkspace(selection: selection)
        XCTAssertEqual(saved.tasks.first { $0.task.id == legacy.id }?.task.extraProperties, legacy.extraProperties)
    }

    func testChildCreationInheritsOnlyParentIdentityAndReparentWritesOnlyChild() async throws {
        var parent = try task(id(1), state: "done", path: "Tasks/nested/\(try id(1).rawValue).md")
        parent.tags = ["parent-only"]
        parent.dueDate = try CivilDate(rawValue: "2026-09-06")
        let destination = try task(id(2))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, service, selection) = try await seed([parent, destination], at: directory)
        let child = try await service.addTask(selection: selection, name: "Independent child", parentID: parent.id)
        XCTAssertEqual(child.parentID, parent.id)
        XCTAssertEqual(child.state, "open")
        XCTAssertTrue(child.tags.isEmpty)
        XCTAssertNil(child.dueDate)
        XCTAssertEqual(child.relativePath, "Tasks/\(child.id.rawValue).md")
        var update = TaskUpdate(task: child)
        update.parentID = destination.id
        let moved = try await service.editTask(selection: selection, id: child.id, expectedTask: child, update: update)
        XCTAssertEqual(moved.parentID, destination.id)
        XCTAssertEqual(moved.relativePath, child.relativePath)
        let workspace = try await service.loadWorkspace(selection: selection)
        XCTAssertEqual(workspace.tasks.first { $0.task.id == parent.id }?.task, parent)
        XCTAssertEqual(workspace.tasks.first { $0.task.id == destination.id }?.task, destination)
        XCTAssertEqual(workspace.pendingChanges.map(\.path), [child.relativePath])
    }

    private func id(_ number: Int) throws -> TaskID {
        try TaskID(rawValue: String(format: "%026d", number))
    }

    private func configuration(_ version: Int = 2) throws -> StoreConfiguration {
        try StoreConfiguration(schemaVersion: version, tasksDirectory: "Tasks", projectsDirectory: "Projects",
                               obsidianLinkPrefix: "", defaultState: "open", states: [
                                WorkflowState(id: "open", name: "Open", isTerminal: false),
                                WorkflowState(id: "done", name: "Done", isTerminal: true),
                               ])
    }

    private func selection() throws -> RepositorySelection {
        try RepositorySelection(owner: "owner", name: "repo", branch: "main", storePath: "")
    }

    private func task(_ id: TaskID, parent: TaskID? = nil, state: String = "open", path: String? = nil) throws -> TodoTask {
        try TodoTask(id: id, relativePath: path ?? "Tasks/\(id.rawValue).md", name: id.rawValue, state: state,
                     projectSlugs: [], tags: [], dueDate: nil, recurrence: nil, recurrenceFrom: nil,
                     lastCompletedDate: nil, body: "Notes\r\n", extraProperties: [], parentID: parent)
    }

    private func seed(_ tasks: [TodoTask], at directory: URL, schema: Int = 2) async throws -> (FileWorkspaceStore, TaskWorkspaceService, RepositorySelection) {
        let configuration = try configuration(schema)
        let selection = try selection()
        let documents = try tasks.map { task in
            TaskDocument(task: task, content: try ObsidianTaskCodec().serializeTask(task, configuration: configuration), blobSHA: "blob-\(task.id.rawValue)")
        }
        let workspace = try WorkspaceState(selection: selection, configuration: configuration, tasks: documents,
                                           baseHeadCommitSHA: "head", baseRootTreeSHA: "tree", pendingChanges: [], conflicts: [])
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(workspace, expectedRevision: nil)
        return (store, TaskWorkspaceService(persistence: store, taskCodec: ObsidianTaskCodec()), selection)
    }
}
