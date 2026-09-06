import Foundation
import XCTest
@testable import OTodoCore

final class WorkspaceTests: XCTestCase, @unchecked Sendable {
    func testWorkspaceMigrationPreservesOfflineOutboxFiltersAndSelection() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("private", isDirectory: true)
        let shared = directory.appendingPathComponent("group/workspace-data", isDirectory: true)
        let legacyWorkspaces = legacy.appendingPathComponent("workspaces", isDirectory: true)
        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let store = FileWorkspaceStore(rootURL: legacyWorkspaces)
        try await store.save(
            makeWorkspace(selection: selection, configuration: configuration),
            expectedRevision: nil
        )
        let service = TaskWorkspaceService(persistence: store, taskCodec: ObsidianTaskCodec())
        let captured = try await service.addTask(
            selection: selection,
            name: "Unsynced before upgrading",
            body: "Keep this Markdown context\n"
        )
        let beforeMigration = try await service.loadWorkspace(selection: selection)
        let customFilter = try SavedTaskFilter(
            id: "capture-review", name: "Capture review", query: "inbox", isStarred: false
        )
        try await FileTaskFilterStore(rootURL: legacyWorkspaces.appendingPathComponent("filters"))
            .save(SavedTaskFilter.defaults + [customFilter], selection: selection)
        try JSONEncoder().encode(selection).write(
            to: legacy.appendingPathComponent("repository-selection.json"), options: .atomic
        )

        try WorkspaceStorageMigration.prepare(legacyURL: legacy, destinationURL: shared)

        let restoredSelection = try JSONDecoder().decode(
            RepositorySelection.self,
            from: Data(contentsOf: shared.appendingPathComponent("repository-selection.json"))
        )
        let sharedWorkspaces = shared.appendingPathComponent("workspaces", isDirectory: true)
        let restoredService = TaskWorkspaceService(
            persistence: FileWorkspaceStore(rootURL: sharedWorkspaces),
            taskCodec: ObsidianTaskCodec()
        )
        let restored = try await restoredService.loadWorkspace(selection: restoredSelection)
        XCTAssertEqual(restored, beforeMigration)
        XCTAssertEqual(restored.tasks.first?.task, captured)
        let filters = try await FileTaskFilterStore(
            rootURL: sharedWorkspaces.appendingPathComponent("filters")
        ).load(selection: restoredSelection)
        XCTAssertEqual(filters.first(where: { $0.id == customFilter.id }), customFilter)

        let second = try await restoredService.addTask(
            selection: restoredSelection, name: "Captured after upgrading"
        )
        // A stale private cache must never overwrite newer shared edits.
        try await FileWorkspaceStore(rootURL: legacyWorkspaces).save(
            makeWorkspace(selection: selection, configuration: configuration), expectedRevision: nil
        )
        try WorkspaceStorageMigration.prepare(legacyURL: legacy, destinationURL: shared)
        let durable = try await restoredService.loadWorkspace(selection: restoredSelection)
        XCTAssertEqual(durable.tasks.map(\.task.id), [captured.id, second.id])
        XCTAssertEqual(durable.pendingChanges.count, 2)
        for document in durable.tasks {
            XCTAssertEqual(
                durable.pendingChanges.first(where: {
                    $0.path == repositoryPath(restoredSelection, document.task.relativePath)
                })?.content,
                document.content
            )
        }
    }

    func testFileWorkspaceStoreRoundTripsCompleteStateAndRejectsUnsupportedVersion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let document = try makeDocument(
            id: taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV"),
            name: "Persisted task",
            state: "doing",
            projectSlugs: ["alpha"],
            tags: ["durable"],
            dueDate: try CivilDate(rawValue: "2026-09-03"),
            body: "Persisted body\n",
            blobSHA: "task-blob",
            configuration: configuration
        )
        let pending = try PendingChange(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            path: repositoryPath(selection, document.task.relativePath),
            baseBlobSHA: "task-blob",
            content: document.content,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let conflict = try SyncConflict(
            path: repositoryPath(selection, "Tasks/01ARZ3NDEKTSV4RRFFQ69G5FAW.md"),
            baseBlobSHA: "base-blob",
            remoteBlobSHA: "remote-blob",
            localContent: "local",
            remoteContent: "remote"
        )
        let workspace = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            tasks: [document],
            pendingChanges: [pending],
            conflicts: [conflict]
        )
        let store = FileWorkspaceStore(rootURL: directory)

        try await store.save(workspace, expectedRevision: nil)

        let reloadedStore = FileWorkspaceStore(rootURL: directory)
        let roundTripped = try await loadRequired(reloadedStore, selection: selection)
        XCTAssertEqual(roundTripped, workspace)

        let workspaceURL = directory.appendingPathComponent(
            "\(FileWorkspaceStore.selectionKey(for: selection)).json"
        )
        let persistedData = try Data(contentsOf: workspaceURL)
        var envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
        )
        envelope["version"] = 999
        let corruptedData = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        try corruptedData.write(to: workspaceURL, options: .atomic)

        do {
            _ = try await reloadedStore.load(selection: selection)
            XCTFail("Expected an unsupported persistence version to be rejected")
        } catch let error as OTodoError {
            guard case .corruptLocalState = error else {
                return XCTFail("Expected corruptLocalState, got \(error)")
            }
        }
    }

    func testFileWorkspaceStoreCreateOnlySaveDoesNotReplaceExistingWorkspace() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let original = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            knownProjectSlugs: ["alpha"]
        )
        let replacement = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            knownProjectSlugs: ["beta"]
        )
        let store = FileWorkspaceStore(rootURL: directory)
        let invalidInitialRevision = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            revision: 1
        )
        do {
            try await store.save(invalidInitialRevision, expectedRevision: nil)
            XCTFail("Expected create-only persistence to require revision zero")
        } catch let error as OTodoError {
            guard case .corruptLocalState = error else {
                return XCTFail("Expected corruptLocalState, got \(error)")
            }
        }
        let missingAfterRejectedCreate = try await store.load(selection: selection)
        XCTAssertNil(missingAfterRejectedCreate)

        try await store.save(original, expectedRevision: nil)

        await assertConflict {
            try await store.save(replacement, expectedRevision: nil)
        }

        let durable = try await loadRequired(store, selection: selection)
        XCTAssertEqual(durable, original)
    }

    func testFileWorkspaceStoreRejectsStaleWriterWithoutOverwritingNewerEdit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let initialDocument = try makeDocument(
            id: taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV"),
            name: "Original",
            configuration: configuration
        )
        let initial = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            tasks: [initialDocument]
        )
        let firstWriter = FileWorkspaceStore(rootURL: directory)
        let staleWriter = FileWorkspaceStore(rootURL: directory)
        try await firstWriter.save(initial, expectedRevision: nil)

        let firstSnapshot = try await loadRequired(firstWriter, selection: selection)
        let staleSnapshot = try await loadRequired(staleWriter, selection: selection)
        let firstDocument = try makeDocument(
            id: initialDocument.task.id,
            name: "Newer edit",
            body: "newer\n",
            blobSHA: initialDocument.blobSHA,
            configuration: configuration
        )
        let staleDocument = try makeDocument(
            id: initialDocument.task.id,
            name: "Stale edit",
            body: "stale\n",
            blobSHA: initialDocument.blobSHA,
            configuration: configuration
        )
        let newer = try makeWorkspace(
            selection: firstSnapshot.selection,
            configuration: firstSnapshot.configuration,
            tasks: [firstDocument],
            revision: firstSnapshot.revision + 1
        )
        let stale = try makeWorkspace(
            selection: staleSnapshot.selection,
            configuration: staleSnapshot.configuration,
            tasks: [staleDocument],
            revision: staleSnapshot.revision + 1
        )

        try await firstWriter.save(newer, expectedRevision: firstSnapshot.revision)
        await assertConflict {
            try await staleWriter.save(stale, expectedRevision: staleSnapshot.revision)
        }

        let durable = try await loadRequired(staleWriter, selection: selection)
        XCTAssertEqual(durable, newer)
        XCTAssertEqual(durable.tasks.first?.task.name, "Newer edit")
    }

    func testAddAndEditAreCanonicalAndDurableWithBaseAndExactBody() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration(obsidianLinkPrefix: "Vault")
        let initial = try makeWorkspace(selection: selection, configuration: configuration)
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)

        let id = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let createdAt = Date(timeIntervalSince1970: 1_700_000_100)
        let pendingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let originalBody = "\r\nFirst line\r\nSecond line\n"
        let addingService = makeService(
            store: store,
            id: id,
            now: createdAt,
            uuid: pendingID
        )

        let added = try await addingService.addTask(
            selection: selection,
            name: "Added task",
            projectSlugs: ["beta", "alpha"],
            tags: ["zeta", "alpha"],
            body: originalBody
        )

        XCTAssertEqual(added.id, id)
        XCTAssertEqual(added.relativePath, "Tasks/\(id.rawValue).md")
        XCTAssertEqual(added.projectSlugs, ["alpha", "beta"])
        XCTAssertEqual(added.tags, ["alpha", "zeta"])
        XCTAssertEqual(added.body, originalBody)
        XCTAssertEqual(
            added.extraProperties,
            [YAMLProperty(name: "base", value: .string("[[Vault/todos.base]]"))]
        )

        let afterAdd = try await loadRequired(
            FileWorkspaceStore(rootURL: directory),
            selection: selection
        )
        XCTAssertEqual(afterAdd.revision, 1)
        XCTAssertEqual(afterAdd.tasks.map(\.task), [added])
        let addedPending = try XCTUnwrap(afterAdd.pendingChanges.first)
        XCTAssertEqual(afterAdd.pendingChanges.count, 1)
        XCTAssertEqual(addedPending.id, pendingID)
        XCTAssertEqual(addedPending.createdAt, createdAt)
        XCTAssertNil(addedPending.baseBlobSHA)
        XCTAssertEqual(addedPending.content, afterAdd.tasks[0].content)

        let editedAt = Date(timeIntervalSince1970: 1_700_000_200)
        let editingService = makeService(
            store: store,
            id: id,
            now: editedAt,
            uuid: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        let editedBody = "Edited body without a trailing newline"
        let edited = try await editingService.editTask(
            selection: selection,
            id: id,
            expectedTask: added,
            update: TaskUpdate(
                name: "Edited task",
                state: "doing",
                projectSlugs: ["beta"],
                tags: ["edited"],
                dueDate: try CivilDate(rawValue: "2026-10-04"),
                dueTime: try CivilTime(rawValue: "14:45"),
                body: editedBody
            )
        )

        let afterEdit = try await loadRequired(
            FileWorkspaceStore(rootURL: directory),
            selection: selection
        )
        XCTAssertEqual(afterEdit.revision, 2)
        XCTAssertEqual(afterEdit.tasks.map(\.task), [edited])
        XCTAssertEqual(afterEdit.tasks[0].task.body, editedBody)
        XCTAssertEqual(afterEdit.tasks[0].task.dueTime, try CivilTime(rawValue: "14:45"))
        XCTAssertTrue(afterEdit.tasks[0].content.contains("due_time: \"14:45\""))
        XCTAssertEqual(afterEdit.tasks[0].task.extraProperties, added.extraProperties)
        XCTAssertEqual(afterEdit.pendingChanges.count, 1)
        XCTAssertEqual(afterEdit.pendingChanges[0].id, pendingID)
        XCTAssertEqual(afterEdit.pendingChanges[0].createdAt, createdAt)
        XCTAssertNil(afterEdit.pendingChanges[0].baseBlobSHA)
        XCTAssertEqual(afterEdit.pendingChanges[0].content, afterEdit.tasks[0].content)
    }

    func testAddTasksPersistsParsedNamesAndOutboxUsingOneReferenceDate() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration(obsidianLinkPrefix: "Vault")
        let initial = try makeWorkspace(selection: selection, configuration: configuration)
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let referenceDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 5, hour: 23, minute: 59
        )))
        let clock = AdvancingBatchClock(date: referenceDate)
        let service = TaskWorkspaceService(
            persistence: store,
            taskCodec: ObsidianTaskCodec(),
            now: { clock.next() }
        )

        let added = try await service.addTasks(
            selection: selection,
            names: [" \t ", "  Buy milk tomorrow  ", "", "Call Alex tomorrow", "Read 2026-10-01"],
            calendar: calendar
        )

        XCTAssertEqual(added.map(\.name), ["Buy milk", "Call Alex", "Read 2026-10-01"])
        XCTAssertEqual(added.map(\.dueDate), [
            try CivilDate(rawValue: "2026-09-06"),
            try CivilDate(rawValue: "2026-09-06"),
            nil,
        ])
        let durable = try await loadRequired(FileWorkspaceStore(rootURL: directory), selection: selection)
        XCTAssertEqual(durable.tasks.map(\.task), added)
        XCTAssertEqual(durable.pendingChanges.count, 3)
        for document in durable.tasks {
            let pending = try XCTUnwrap(durable.pendingChanges.first {
                $0.path == repositoryPath(selection, document.task.relativePath)
            })
            let uploadedTask = try ObsidianTaskCodec().parseTask(
                id: document.task.id,
                relativePath: document.task.relativePath,
                text: try XCTUnwrap(pending.content),
                configuration: configuration
            )
            XCTAssertEqual(uploadedTask, document.task)
            XCTAssertNil(pending.baseBlobSHA)
        }
    }

    func testAddTasksRejectsLaterInvalidNameWithoutPersistingEarlierTask() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try makeSelection()
        let initial = try makeWorkspace(selection: selection, configuration: makeConfiguration())
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)
        let service = TaskWorkspaceService(persistence: store, taskCodec: ObsidianTaskCodec())

        do {
            _ = try await service.addTasks(selection: selection, names: ["Valid first task", "tomorrow"])
            XCTFail("Expected a date phrase without a task name to be rejected")
        } catch let error as OTodoError {
            guard case .validation(field: "name", message: _) = error else {
                return XCTFail("Expected task name validation, got \(error)")
            }
        }

        let durable = try await loadRequired(FileWorkspaceStore(rootURL: directory), selection: selection)
        XCTAssertEqual(durable, initial)
    }

    func testAddTasksRejectsBlankBatchWithoutChangingWorkspace() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try makeSelection()
        let initial = try makeWorkspace(selection: selection, configuration: makeConfiguration())
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)
        let service = TaskWorkspaceService(persistence: store, taskCodec: ObsidianTaskCodec())

        do {
            _ = try await service.addTasks(selection: selection, names: [" ", "\t", "\r"])
            XCTFail("Expected an empty batch to be rejected")
        } catch let error as OTodoError {
            guard case .validation = error else {
                return XCTFail("Expected validation, got \(error)")
            }
        }

        let durable = try await loadRequired(FileWorkspaceStore(rootURL: directory), selection: selection)
        XCTAssertEqual(durable, initial)
    }

    func testAddTasksSaveFailureLeavesDurableWorkspaceUnchanged() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try makeSelection()
        let initial = try makeWorkspace(selection: selection, configuration: makeConfiguration())
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)
        let service = TaskWorkspaceService(
            persistence: CapacityLimitedWorkspaceStore(store: store, maximumTaskCount: 1),
            taskCodec: ObsidianTaskCodec()
        )

        do {
            _ = try await service.addTasks(selection: selection, names: ["First task", "Second task"])
            XCTFail("Expected persistence failure")
        } catch let error as OTodoError {
            guard case .corruptLocalState = error else {
                return XCTFail("Expected persistence failure, got \(error)")
            }
        }

        let durable = try await loadRequired(FileWorkspaceStore(rootURL: directory), selection: selection)
        XCTAssertEqual(durable, initial)
    }

    func testAddTasksAvoidsExistingPendingConflictedAndStagedIDs() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let ids = [
            taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV"),
            taskID("01ARZ3NDEKTSV4RRFFQ69G5FAW"),
            taskID("01ARZ3NDEKTSV4RRFFQ69G5FAX"),
            taskID("01ARZ3NDEKTSV4RRFFQ69G5FAY"),
            taskID("01ARZ3NDEKTSV4RRFFQ69G5FAZ"),
        ]
        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = try makeDocument(id: ids[0], name: "Existing task", configuration: configuration)
        let pending = try PendingChange(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            path: repositoryPath(selection, "Tasks/\(ids[1].rawValue).md"),
            baseBlobSHA: "deleted-blob",
            content: nil,
            createdAt: referenceDate
        )
        let conflict = try SyncConflict(
            path: repositoryPath(selection, "Tasks/\(ids[2].rawValue).md"),
            baseBlobSHA: "base-blob",
            remoteBlobSHA: "remote-blob",
            localContent: nil,
            remoteContent: "remote"
        )
        let initial = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            tasks: [existing],
            pendingChanges: [pending],
            conflicts: [conflict]
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)
        let service = TaskWorkspaceService(
            persistence: store,
            taskCodec: ObsidianTaskCodec(),
            ulidGenerator: RetryingBatchULIDGenerator(ids: ids, referenceDate: referenceDate),
            now: { referenceDate }
        )

        let added = try await service.addTasks(selection: selection, names: ["First task", "Second task"])

        XCTAssertEqual(added.map(\.id), Array(ids.suffix(2)))
        let durable = try await loadRequired(FileWorkspaceStore(rootURL: directory), selection: selection)
        XCTAssertEqual(durable.tasks.map(\.task), [existing.task] + added)
        XCTAssertEqual(durable.pendingChanges.first, pending)
        XCTAssertEqual(durable.pendingChanges.count, 3)
        XCTAssertEqual(durable.conflicts, [conflict])
    }

    func testAddProjectCreatesCanonicalDurableRecordAndRejectsDuplicates() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let initial = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            knownProjectSlugs: ["alpha"]
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)

        let createdAt = Date(timeIntervalSince1970: 1_700_000_300)
        let pendingID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let service = makeService(
            store: store,
            id: taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV"),
            now: createdAt,
            uuid: pendingID
        )

        let slug = try await service.addProject(
            selection: selection,
            slug: "side-project",
            title: "  Side Project  "
        )
        XCTAssertEqual(slug, "side-project")

        let durable = try await loadRequired(
            FileWorkspaceStore(rootURL: directory),
            selection: selection
        )
        XCTAssertEqual(durable.revision, 1)
        XCTAssertEqual(durable.knownProjectSlugs, ["alpha", "side-project"])
        let pending = try XCTUnwrap(durable.pendingChanges.first)
        XCTAssertEqual(durable.pendingChanges.count, 1)
        XCTAssertEqual(pending.id, pendingID)
        XCTAssertEqual(pending.path, repositoryPath(selection, "Projects/side-project.md"))
        XCTAssertNil(pending.baseBlobSHA)
        XCTAssertEqual(pending.content, "# Side Project\n")
        XCTAssertEqual(pending.createdAt, createdAt)

        do {
            _ = try await service.addProject(
                selection: selection,
                slug: "side-project",
                title: "Duplicate"
            )
            XCTFail("Expected duplicate project creation to fail")
        } catch {
            XCTAssertEqual(
                error as? OTodoError,
                .validation(
                    field: "projects",
                    message: "Project side-project already exists"
                )
            )
        }

        let unchanged = try await loadRequired(store, selection: selection)
        XCTAssertEqual(unchanged, durable)
    }

    func testReschedulingPreservesMixedTimesAndUneditedTaskDataDurably() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let documents = try makeReschedulingDocuments(configuration: configuration)
        let initial = try makeWorkspace(
            selection: selection, configuration: configuration, tasks: documents
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)
        let service = TaskWorkspaceService(persistence: store, taskCodec: ObsidianTaskCodec())
        let newDate = try CivilDate(rawValue: "2027-04-05")
        let selected = [documents[2].task, documents[0].task, documents[1].task]

        let dateOnly = try await service.rescheduleTasks(
            selection: selection, expectedTasks: selected,
            dueDate: .set(newDate), dueTime: .preserve
        )
        let expectedDateOnly = selected.map { task in
            var expected = task
            expected.dueDate = newDate
            return expected
        }
        XCTAssertEqual(dateOnly, expectedDateOnly)
        let dated = try await loadRequired(FileWorkspaceStore(rootURL: directory), selection: selection)
        XCTAssertEqual(dated.tasks.map(\.task.id), documents.map(\.task.id))
        XCTAssertEqual(dated.tasks.map(\.task.dueTime), documents.map(\.task.dueTime))
        XCTAssertEqual(dated.pendingChanges.count, documents.count)
        for document in dated.tasks {
            let pending = try XCTUnwrap(dated.pendingChanges.first {
                $0.path == repositoryPath(selection, document.task.relativePath)
            })
            XCTAssertEqual(pending.baseBlobSHA, document.blobSHA)
            XCTAssertEqual(pending.content, document.content)
            let parsed = try ObsidianTaskCodec().parseTask(
                id: document.task.id, relativePath: document.task.relativePath,
                text: try XCTUnwrap(pending.content), configuration: configuration
            )
            XCTAssertEqual(parsed, document.task)
        }

        let time = try CivilTime(rawValue: "14:25")
        // Restore one distinct date so time-only edits must preserve each task's own date.
        let distinct = try await service.rescheduleTasks(
            selection: selection, expectedTasks: [dateOnly[0]],
            dueDate: .set(try CivilDate(rawValue: "2027-04-09")), dueTime: .preserve
        )
        let timeSelection = [distinct[0], dateOnly[1], dateOnly[2]]
        let timed = try await service.rescheduleTasks(
            selection: selection, expectedTasks: timeSelection,
            dueDate: .preserve, dueTime: .set(time)
        )
        XCTAssertEqual(timed, timeSelection.map { task in
            var expected = task
            expected.dueTime = time
            return expected
        })
        let durable = try await loadRequired(FileWorkspaceStore(rootURL: directory), selection: selection)
        XCTAssertEqual(durable.tasks.map(\.task.dueDate), [newDate, newDate, distinct[0].dueDate])
        XCTAssertEqual(durable.pendingChanges.count, dated.pendingChanges.count)
        for pending in durable.pendingChanges {
            let original = try XCTUnwrap(dated.pendingChanges.first { $0.path == pending.path })
            XCTAssertEqual(pending.id, original.id)
            XCTAssertEqual(pending.baseBlobSHA, original.baseBlobSHA)
            XCTAssertEqual(pending.createdAt, original.createdAt)
            XCTAssertEqual(pending.content, durable.tasks.first {
                repositoryPath(selection, $0.task.relativePath) == pending.path
            }?.content)
        }
    }

    func testReschedulingClearsTimeAndDateWithoutLeavingOrphanTimes() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        // The third fixture is recurring and cannot lose its date.
        let documents = Array(try makeReschedulingDocuments(configuration: configuration).prefix(2))
        let initial = try makeWorkspace(
            selection: selection, configuration: configuration, tasks: documents
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)
        let service = TaskWorkspaceService(persistence: store, taskCodec: ObsidianTaskCodec())
        let clearedTime = try await service.rescheduleTasks(
            selection: selection, expectedTasks: documents.map(\.task),
            dueDate: .preserve, dueTime: .clear
        )
        XCTAssertEqual(clearedTime, documents.map { document in
            var expected = document.task
            expected.dueTime = nil
            return expected
        })
        let timed = try await service.rescheduleTasks(
            selection: selection, expectedTasks: clearedTime,
            dueDate: .preserve, dueTime: .set(try CivilTime(rawValue: "10:30"))
        )
        let undated = try await service.rescheduleTasks(
            selection: selection, expectedTasks: timed,
            dueDate: .clear, dueTime: .preserve
        )
        XCTAssertEqual(undated, documents.map { document in
            var expected = document.task
            expected.dueDate = nil
            expected.dueTime = nil
            return expected
        })
        let durable = try await loadRequired(FileWorkspaceStore(rootURL: directory), selection: selection)
        XCTAssertEqual(durable.tasks.map(\.task), undated)
        for document in durable.tasks {
            let parsed = try ObsidianTaskCodec().parseTask(
                id: document.task.id, relativePath: document.task.relativePath,
                text: document.content, configuration: configuration
            )
            XCTAssertNil(parsed.dueDate)
            XCTAssertNil(parsed.dueTime)
        }
    }

    func testInvalidReschedulingRollsBackEarlierTasksAndOutbox() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let documents = try makeReschedulingDocuments(configuration: configuration)
        let initial = try makeWorkspace(
            selection: selection, configuration: configuration, tasks: documents
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)
        let service = TaskWorkspaceService(persistence: store, taskCodec: ObsidianTaskCodec())
        let time = try CivilTime(rawValue: "12:00")
        // Clearing a later recurring task must also roll back earlier valid changes.
        await assertReschedulingValidation {
            _ = try await service.rescheduleTasks(
                selection: selection, expectedTasks: documents.map(\.task),
                dueDate: .clear, dueTime: .preserve
            )
        }
        await assertReschedulingValidation {
            _ = try await service.rescheduleTasks(
                selection: selection, expectedTasks: [documents[0].task],
                dueDate: .clear, dueTime: .set(time)
            )
        }
        let unchanged = try await loadRequired(store, selection: selection)
        XCTAssertEqual(unchanged, initial)
        let undated = try await service.rescheduleTasks(
            selection: selection, expectedTasks: [documents[1].task],
            dueDate: .clear, dueTime: .clear
        )
        let beforeTimeOnly = try await loadRequired(store, selection: selection)
        await assertReschedulingValidation {
            _ = try await service.rescheduleTasks(
                selection: selection, expectedTasks: [documents[0].task, undated[0]],
                dueDate: .preserve, dueTime: .set(time)
            )
        }
        let afterTimeOnly = try await loadRequired(FileWorkspaceStore(rootURL: directory), selection: selection)
        XCTAssertEqual(afterTimeOnly, beforeTimeOnly)
        let date = try CivilDate(rawValue: "2027-06-07")
        let dated = try await service.rescheduleTasks(
            selection: selection, expectedTasks: [documents[0].task, undated[0]],
            dueDate: .set(date), dueTime: .set(time)
        )
        XCTAssertEqual(dated.map(\.dueDate), [date, date])
        XCTAssertEqual(dated.map(\.dueTime), [time, time])
    }

    func testReschedulingRejectsEmptyDuplicateStaleMissingAndConflictedSelectionsAtomically() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let documents = try makeReschedulingDocuments(configuration: configuration)
        let initial = try makeWorkspace(
            selection: selection, configuration: configuration, tasks: documents
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)
        let service = TaskWorkspaceService(persistence: store, taskCodec: ObsidianTaskCodec())
        let date = try CivilDate(rawValue: "2027-05-06")
        for invalidSelection in [[], [documents[0].task, documents[0].task]] {
            await assertReschedulingValidation {
                _ = try await service.rescheduleTasks(
                    selection: selection, expectedTasks: invalidSelection,
                    dueDate: .set(date), dueTime: .preserve
                )
            }
        }
        var stale = documents[1].task
        stale.name = "Outdated version"
        await assertConflict {
            _ = try await service.rescheduleTasks(
                selection: selection, expectedTasks: [documents[0].task, stale],
                dueDate: .set(date), dueTime: .preserve
            )
        }
        let missing = try makeDocument(
            id: taskID("01ARZ3NDEKTSV4RRFFQ69G5FAZ"), name: "Deleted",
            configuration: configuration
        )
        do {
            _ = try await service.rescheduleTasks(
                selection: selection, expectedTasks: [documents[0].task, missing.task],
                dueDate: .set(date), dueTime: .preserve
            )
            XCTFail("Expected missing task rejection")
        } catch let error as OTodoError {
            guard case .notFound = error else { return XCTFail("Expected notFound, got \(error)") }
        }
        let unchanged = try await loadRequired(store, selection: selection)
        XCTAssertEqual(unchanged, initial)

        let pending = try PendingChange(
            id: UUID(), path: repositoryPath(selection, documents[1].task.relativePath),
            baseBlobSHA: documents[1].blobSHA, content: documents[1].content, createdAt: .now
        )
        let conflict = try SyncConflict(
            path: pending.path, baseBlobSHA: pending.baseBlobSHA, remoteBlobSHA: "remote-new",
            localContent: pending.content, remoteContent: "Remote version"
        )
        let conflicted = try makeWorkspace(
            selection: selection, configuration: configuration, tasks: documents,
            pendingChanges: [pending], conflicts: [conflict], revision: 1
        )
        try await store.save(conflicted, expectedRevision: initial.revision)
        await assertConflict {
            _ = try await service.rescheduleTasks(
                selection: selection, expectedTasks: documents.map(\.task),
                dueDate: .set(date), dueTime: .preserve
            )
        }
        let afterConflict = try await loadRequired(FileWorkspaceStore(rootURL: directory), selection: selection)
        XCTAssertEqual(afterConflict, conflicted)
    }

    func testReschedulingSaveFailureLeavesDurableBatchUnchanged() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let documents = try makeReschedulingDocuments(configuration: configuration)
        let initial = try makeWorkspace(
            selection: selection, configuration: configuration, tasks: documents
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)
        let service = TaskWorkspaceService(
            persistence: CapacityLimitedWorkspaceStore(store: store, maximumTaskCount: 0),
            taskCodec: ObsidianTaskCodec()
        )
        do {
            _ = try await service.rescheduleTasks(
                selection: selection, expectedTasks: documents.map(\.task),
                dueDate: .set(try CivilDate(rawValue: "2027-07-08")), dueTime: .preserve
            )
            XCTFail("Expected storage failure")
        } catch let error as OTodoError {
            guard case .corruptLocalState = error else {
                return XCTFail("Expected storage failure, got \(error)")
            }
        }
        let durable = try await loadRequired(FileWorkspaceStore(rootURL: directory), selection: selection)
        XCTAssertEqual(durable, initial)
    }

    func testRepeatedEditsCoalesceOutboxAndRetainOriginalBaseIDAndTime() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let id = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let originalDocument = try makeDocument(
            id: id,
            name: "Original",
            body: "Original body\n",
            blobSHA: "original-blob",
            configuration: configuration
        )
        let initial = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            tasks: [originalDocument]
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)

        let originalPendingID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let firstEditTime = Date(timeIntervalSince1970: 1_700_001_000)
        let firstService = makeService(
            store: store,
            id: id,
            now: firstEditTime,
            uuid: originalPendingID
        )
        _ = try await firstService.editTask(
            selection: selection,
            id: id,
            expectedTask: originalDocument.task,
            update: TaskUpdate(
                name: "First edit",
                state: "backlog",
                projectSlugs: ["alpha"],
                tags: ["first"],
                dueDate: nil,
                body: "First body\n"
            )
        )

        let firstDurable = try await loadRequired(store, selection: selection)
        let firstPending = try XCTUnwrap(firstDurable.pendingChanges.first)
        XCTAssertEqual(firstPending.id, originalPendingID)
        XCTAssertEqual(firstPending.baseBlobSHA, "original-blob")
        XCTAssertEqual(firstPending.createdAt, firstEditTime)

        let secondService = makeService(
            store: store,
            id: id,
            now: Date(timeIntervalSince1970: 1_800_002_000),
            uuid: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        )
        let latest = try await secondService.editTask(
            selection: selection,
            id: id,
            expectedTask: firstDurable.tasks[0].task,
            update: TaskUpdate(
                name: "Latest edit",
                state: "doing",
                projectSlugs: ["beta"],
                tags: ["latest"],
                dueDate: try CivilDate(rawValue: "2027-01-02"),
                body: "Latest body\n"
            )
        )

        let durable = try await loadRequired(
            FileWorkspaceStore(rootURL: directory),
            selection: selection
        )
        XCTAssertEqual(durable.revision, 2)
        XCTAssertEqual(durable.tasks.map(\.task), [latest])
        XCTAssertEqual(durable.pendingChanges.count, 1)
        let coalesced = durable.pendingChanges[0]
        XCTAssertEqual(coalesced.id, originalPendingID)
        XCTAssertEqual(coalesced.baseBlobSHA, "original-blob")
        XCTAssertEqual(coalesced.createdAt, firstEditTime)
        XCTAssertEqual(coalesced.content, durable.tasks[0].content)
        XCTAssertNotEqual(coalesced.content, firstPending.content)
    }

    func testDeletingSyncedTaskCoalescesPendingEditIntoDurableDeletion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let id = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let original = try makeDocument(
            id: id,
            name: "Original",
            blobSHA: "original-blob",
            configuration: configuration
        )
        let initial = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            tasks: [original]
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)

        let pendingID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let mutationTime = Date(timeIntervalSince1970: 1_700_001_500)
        let service = makeService(
            store: store,
            id: id,
            now: mutationTime,
            uuid: pendingID
        )
        let edited = try await service.editTask(
            selection: selection,
            id: id,
            expectedTask: original.task,
            update: TaskUpdate(
                name: "Edited before deletion",
                state: "doing",
                projectSlugs: ["alpha"],
                tags: ["edited"],
                dueDate: nil,
                body: "Edited body\n"
            )
        )

        try await service.deleteTask(
            selection: selection,
            id: id,
            expectedTask: edited
        )

        let durable = try await loadRequired(
            FileWorkspaceStore(rootURL: directory),
            selection: selection
        )
        XCTAssertEqual(durable.revision, 2)
        XCTAssertTrue(durable.tasks.isEmpty)
        let deletion = try XCTUnwrap(durable.pendingChanges.first)
        XCTAssertEqual(durable.pendingChanges.count, 1)
        XCTAssertEqual(deletion.id, pendingID)
        XCTAssertEqual(deletion.path, repositoryPath(selection, original.task.relativePath))
        XCTAssertEqual(deletion.baseBlobSHA, "original-blob")
        XCTAssertNil(deletion.content)
        XCTAssertEqual(deletion.createdAt, mutationTime)
    }

    func testDeletingUnsyncedTaskCancelsCreateOutboxEntry() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let initial = try makeWorkspace(selection: selection, configuration: configuration)
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)

        let id = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let service = makeService(
            store: store,
            id: id,
            now: Date(timeIntervalSince1970: 1_700_001_600),
            uuid: UUID(uuidString: "13131313-1313-1313-1313-131313131313")!
        )
        let added = try await service.addTask(
            selection: selection,
            name: "Never synchronized"
        )
        try await service.deleteTask(
            selection: selection,
            id: id,
            expectedTask: added
        )

        let durable = try await loadRequired(
            FileWorkspaceStore(rootURL: directory),
            selection: selection
        )
        XCTAssertEqual(durable.revision, 2)
        XCTAssertTrue(durable.tasks.isEmpty)
        XCTAssertTrue(durable.pendingChanges.isEmpty)
    }

    func testEditAndDeleteRejectStaleExpectedTaskWithoutMutation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let id = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let staleDocument = try makeDocument(
            id: id,
            name: "Draft version",
            body: "Draft body\n",
            blobSHA: "stale-blob",
            configuration: configuration
        )
        let initial = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            tasks: [staleDocument]
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)

        let currentDocument = try makeDocument(
            id: id,
            name: "Synced version",
            state: "doing",
            body: "Synced body\n",
            blobSHA: "synced-blob",
            configuration: configuration
        )
        let synchronized = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            tasks: [currentDocument],
            revision: 1
        )
        try await store.save(synchronized, expectedRevision: initial.revision)
        let beforeStaleEdit = try await loadRequired(store, selection: selection)

        let service = makeService(
            store: store,
            id: id,
            now: Date(timeIntervalSince1970: 1_700_002_000),
            uuid: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        )
        let update = TaskUpdate(
            name: "User edit",
            state: "backlog",
            projectSlugs: ["alpha"],
            tags: ["edited"],
            dueDate: try CivilDate(rawValue: "2027-02-03"),
            body: "User body\n"
        )

        await assertConflict {
            _ = try await service.editTask(
                selection: selection,
                id: id,
                expectedTask: staleDocument.task,
                update: update
            )
        }
        await assertConflict {
            try await service.deleteTask(
                selection: selection,
                id: id,
                expectedTask: staleDocument.task
            )
        }

        let afterStaleMutations = try await loadRequired(store, selection: selection)
        XCTAssertEqual(afterStaleMutations, beforeStaleEdit)
        XCTAssertEqual(afterStaleMutations.revision, beforeStaleEdit.revision)
        XCTAssertEqual(afterStaleMutations.tasks[0].content, beforeStaleEdit.tasks[0].content)
        XCTAssertEqual(afterStaleMutations.pendingChanges, beforeStaleEdit.pendingChanges)

        let edited = try await service.editTask(
            selection: selection,
            id: id,
            expectedTask: currentDocument.task,
            update: update
        )
        let afterCurrentEdit = try await loadRequired(store, selection: selection)
        XCTAssertEqual(afterCurrentEdit.revision, beforeStaleEdit.revision + 1)
        XCTAssertEqual(afterCurrentEdit.tasks.map(\.task), [edited])
        XCTAssertEqual(afterCurrentEdit.pendingChanges.count, 1)
        XCTAssertEqual(afterCurrentEdit.pendingChanges[0].baseBlobSHA, "synced-blob")
        XCTAssertEqual(afterCurrentEdit.pendingChanges[0].content, afterCurrentEdit.tasks[0].content)
    }

    func testInvalidStateAndProjectEditsDoNotPersistAnything() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let id = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let document = try makeDocument(
            id: id,
            name: "Unchanged",
            projectSlugs: ["alpha"],
            blobSHA: "original-blob",
            configuration: configuration
        )
        let initial = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            tasks: [document]
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)
        let service = makeService(
            store: store,
            id: taskID("01ARZ3NDEKTSV4RRFFQ69G5FAW"),
            now: Date(timeIntervalSince1970: 1_700_003_000),
            uuid: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )

        do {
            _ = try await service.editTask(
                selection: selection,
                id: id,
                expectedTask: document.task,
                update: TaskUpdate(
                    name: "Must not persist",
                    state: "missing",
                    projectSlugs: ["alpha"],
                    tags: [],
                    dueDate: nil,
                    body: "Must not persist"
                )
            )
            XCTFail("Expected an unconfigured state to be rejected")
        } catch let error as OTodoError {
            guard case let .validation(field, _) = error else {
                return XCTFail("Expected validation, got \(error)")
            }
            XCTAssertEqual(field, "state")
        }
        let afterInvalidState = try await store.load(selection: selection)
        XCTAssertEqual(afterInvalidState, initial)

        do {
            _ = try await service.editTask(
                selection: selection,
                id: id,
                expectedTask: document.task,
                update: TaskUpdate(
                    name: "Must not persist",
                    state: "backlog",
                    projectSlugs: ["unknown-project"],
                    tags: [],
                    dueDate: nil,
                    body: "Must not persist"
                )
            )
            XCTFail("Expected an unknown project to be rejected")
        } catch let error as OTodoError {
            guard case let .validation(field, _) = error else {
                return XCTFail("Expected validation, got \(error)")
            }
            XCTAssertEqual(field, "projects")
        }
        let afterInvalidProject = try await store.load(selection: selection)
        XCTAssertEqual(afterInvalidProject, initial)
    }

    func testListTasksFiltersTerminalTasksAndUsesStableSortContract() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let terminalID = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let lowercaseID = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAW")
        let firstUppercaseID = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAX")
        let secondUppercaseID = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAY")
        let mixedCaseID = taskID("01ARZ3NDEKTSV4RRFFQ69G5FB1")
        let doingID = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAZ")
        let undatedID = taskID("01ARZ3NDEKTSV4RRFFQ69G5FB0")
        let earlyDate = try CivilDate(rawValue: "2026-01-01")
        let terminalDate = try CivilDate(rawValue: "2025-12-31")
        let documents = try [
            makeDocument(
                id: undatedID,
                name: "Undated",
                state: "backlog",
                configuration: configuration
            ),
            makeDocument(
                id: doingID,
                name: "Aardvark",
                state: "doing",
                dueDate: earlyDate,
                configuration: configuration
            ),
            makeDocument(
                id: lowercaseID,
                name: "alpha",
                state: "backlog",
                dueDate: earlyDate,
                configuration: configuration
            ),
            makeDocument(
                id: secondUppercaseID,
                name: "Alpha",
                state: "backlog",
                dueDate: earlyDate,
                configuration: configuration
            ),
            makeDocument(
                id: mixedCaseID,
                name: "Beta",
                state: "backlog",
                dueDate: earlyDate,
                configuration: configuration
            ),
            makeDocument(
                id: terminalID,
                name: "Completed",
                state: "done",
                dueDate: terminalDate,
                configuration: configuration
            ),
            makeDocument(
                id: firstUppercaseID,
                name: "Alpha",
                state: "backlog",
                dueDate: earlyDate,
                configuration: configuration
            ),
        ]
        let workspace = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            tasks: documents
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(workspace, expectedRevision: nil)
        let service = makeService(
            store: store,
            id: taskID("01ARZ3NDEKTSV4RRFFQ69G5FB2"),
            now: Date(timeIntervalSince1970: 1_700_004_000),
            uuid: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        )

        let active = try await service.listTasks(selection: selection)
        XCTAssertEqual(
            active.map(\.id),
            [firstUppercaseID, secondUppercaseID, mixedCaseID, lowercaseID, doingID, undatedID]
        )
        XCTAssertFalse(active.contains(where: { $0.state == "done" }))

        let all = try await service.listTasks(selection: selection, includeTerminal: true)
        XCTAssertEqual(
            all.map(\.id),
            [terminalID, firstUppercaseID, secondUppercaseID, mixedCaseID, lowercaseID, doingID, undatedID]
        )
    }

    func testListTasksOrdersDateOnlyBeforeTimedTasksAndTimesAscending() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let dueDate = try CivilDate(rawValue: "2026-01-01")
        let dateOnlyID = taskID("01ARZ3NDEKTSV4RRFFQ69G5FB3")
        let morningID = taskID("01ARZ3NDEKTSV4RRFFQ69G5FB4")
        let afternoonID = taskID("01ARZ3NDEKTSV4RRFFQ69G5FB5")
        let workspace = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            tasks: [
                makeDocument(
                    id: afternoonID,
                    name: "Afternoon",
                    dueDate: dueDate,
                    dueTime: try CivilTime(rawValue: "14:30"),
                    configuration: configuration
                ),
                makeDocument(
                    id: dateOnlyID,
                    name: "Date only",
                    dueDate: dueDate,
                    configuration: configuration
                ),
                makeDocument(
                    id: morningID,
                    name: "Morning",
                    dueDate: dueDate,
                    dueTime: try CivilTime(rawValue: "09:15"),
                    configuration: configuration
                ),
            ]
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(workspace, expectedRevision: nil)
        let service = makeService(
            store: store,
            id: taskID("01ARZ3NDEKTSV4RRFFQ69G5FB6"),
            now: Date(timeIntervalSince1970: 1_700_004_000),
            uuid: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        )

        let active = try await service.listTasks(selection: selection)

        XCTAssertEqual(active.map(\.id), [dateOnlyID, morningID, afternoonID])
    }

    func testUseRemoteConflictResolutionPersistsExactRemoteTaskAndClearsOverlay() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let id = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let localDocument = try makeDocument(
            id: id,
            name: "Local",
            body: "Local body\n",
            blobSHA: "base-blob",
            configuration: configuration
        )
        let path = repositoryPath(selection, localDocument.task.relativePath)
        let pending = try PendingChange(
            id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            path: path,
            baseBlobSHA: "base-blob",
            content: localDocument.content,
            createdAt: Date(timeIntervalSince1970: 1_700_005_000)
        )
        let remoteContent = """
        ---
        tags: []
        projects: []
        state: done
        name: "Remote task"
        ---
        Exact remote body
        """
        let conflict = try SyncConflict(
            path: path,
            baseBlobSHA: "base-blob",
            remoteBlobSHA: "remote-blob",
            localContent: localDocument.content,
            remoteContent: remoteContent
        )
        let initial = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            tasks: [localDocument],
            pendingChanges: [pending],
            conflicts: [conflict]
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)
        let service = makeService(
            store: store,
            id: id,
            now: Date(timeIntervalSince1970: 1_700_006_000),
            uuid: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        )

        let resolved = try await service.resolveConflict(
            selection: selection,
            path: path,
            resolution: .useRemote
        )

        let expectedTask = try ObsidianTaskCodec().parseTask(
            id: id,
            relativePath: localDocument.task.relativePath,
            text: remoteContent,
            configuration: configuration
        )
        XCTAssertEqual(resolved.tasks, [
            TaskDocument(task: expectedTask, content: remoteContent, blobSHA: "remote-blob"),
        ])
        XCTAssertTrue(resolved.pendingChanges.isEmpty)
        XCTAssertTrue(resolved.conflicts.isEmpty)
        XCTAssertEqual(resolved.revision, 1)
        let durable = try await store.load(selection: selection)
        XCTAssertEqual(durable, resolved)
    }

    func testKeepLocalConflictResolutionCanonicalizesAndRebasesDurableOutbox() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let id = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let original = try makeDocument(
            id: id,
            name: "Original",
            body: "Original body\n",
            blobSHA: "base-blob",
            configuration: configuration
        )
        let path = repositoryPath(selection, original.task.relativePath)
        let pendingID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let pendingTime = Date(timeIntervalSince1970: 1_700_007_000)
        let localContent = """
        ---
        tags:
          - zeta
          - alpha
        projects:
          - "[[Projects/alpha]]"
        state: doing
        name: "Local kept"
        base: "[[todos.base]]"
        ---
        Local body
        """
        let pending = try PendingChange(
            id: pendingID,
            path: path,
            baseBlobSHA: "base-blob",
            content: localContent,
            createdAt: pendingTime
        )
        let conflict = try SyncConflict(
            path: path,
            baseBlobSHA: "base-blob",
            remoteBlobSHA: "remote-blob",
            localContent: localContent,
            remoteContent: "remote replacement"
        )
        let initial = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            tasks: [original],
            pendingChanges: [pending],
            conflicts: [conflict]
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)
        let service = makeService(
            store: store,
            id: id,
            now: Date(timeIntervalSince1970: 1_800_007_000),
            uuid: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )

        let resolved = try await service.resolveConflict(
            selection: selection,
            path: path,
            resolution: .keepLocal
        )

        let parsedLocal = try ObsidianTaskCodec().parseTask(
            id: id,
            relativePath: original.task.relativePath,
            text: localContent,
            configuration: configuration
        )
        let canonicalContent = try ObsidianTaskCodec().serializeTask(
            parsedLocal,
            configuration: configuration
        )
        let canonicalTask = try ObsidianTaskCodec().parseTask(
            id: id,
            relativePath: original.task.relativePath,
            text: canonicalContent,
            configuration: configuration
        )
        XCTAssertNotEqual(canonicalContent, localContent)
        XCTAssertEqual(resolved.tasks, [
            TaskDocument(task: canonicalTask, content: canonicalContent, blobSHA: "remote-blob"),
        ])
        XCTAssertTrue(resolved.conflicts.isEmpty)
        XCTAssertEqual(resolved.pendingChanges.count, 1)
        let rebased = resolved.pendingChanges[0]
        XCTAssertEqual(rebased.id, pendingID)
        XCTAssertEqual(rebased.path, path)
        XCTAssertEqual(rebased.baseBlobSHA, "remote-blob")
        XCTAssertEqual(rebased.createdAt, pendingTime)
        XCTAssertEqual(rebased.content, canonicalContent)
        let durable = try await store.load(selection: selection)
        XCTAssertEqual(durable, resolved)
    }

    func testKeepLocalDeletionConflictRebasesDurableDeleteOutbox() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration()
        let id = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let relativePath = "\(configuration.tasksDirectory)/\(id.rawValue).md"
        let path = repositoryPath(selection, relativePath)
        let pendingID = UUID(uuidString: "14141414-1414-1414-1414-141414141414")!
        let pendingTime = Date(timeIntervalSince1970: 1_700_007_500)
        let pending = try PendingChange(
            id: pendingID,
            path: path,
            baseBlobSHA: "base-blob",
            content: nil,
            createdAt: pendingTime
        )
        let conflict = try SyncConflict(
            path: path,
            baseBlobSHA: "base-blob",
            remoteBlobSHA: "remote-blob",
            localContent: nil,
            remoteContent: "remote replacement"
        )
        let initial = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            tasks: [],
            pendingChanges: [pending],
            conflicts: [conflict]
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)
        let service = makeService(
            store: store,
            id: id,
            now: Date(timeIntervalSince1970: 1_800_007_500),
            uuid: UUID(uuidString: "15151515-1515-1515-1515-151515151515")!
        )

        let resolved = try await service.resolveConflict(
            selection: selection,
            path: path,
            resolution: .keepLocal
        )

        XCTAssertTrue(resolved.tasks.isEmpty)
        XCTAssertTrue(resolved.conflicts.isEmpty)
        let rebased = try XCTUnwrap(resolved.pendingChanges.first)
        XCTAssertEqual(resolved.pendingChanges.count, 1)
        XCTAssertEqual(rebased.id, pendingID)
        XCTAssertEqual(rebased.path, path)
        XCTAssertEqual(rebased.baseBlobSHA, "remote-blob")
        XCTAssertNil(rebased.content)
        XCTAssertEqual(rebased.createdAt, pendingTime)
        let durable = try await FileWorkspaceStore(rootURL: directory).load(selection: selection)
        XCTAssertEqual(durable, resolved)
    }

    func testUseRemoteConflictAtOldTasksDirectoryDiscardsOnlyRetiredOverlay() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try makeSelection()
        let configuration = try makeConfiguration(tasksDirectory: "NewTasks")
        let oldID = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let currentID = taskID("01ARZ3NDEKTSV4RRFFQ69G5FAW")
        let oldDocument = try makeDocument(
            id: oldID,
            relativePath: "OldTasks/\(oldID.rawValue).md",
            name: "Retired path",
            blobSHA: "old-blob",
            configuration: configuration
        )
        let currentDocument = try makeDocument(
            id: currentID,
            name: "Current path",
            blobSHA: "current-blob",
            configuration: configuration
        )
        let oldPath = repositoryPath(selection, oldDocument.task.relativePath)
        let pending = try PendingChange(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            path: oldPath,
            baseBlobSHA: "old-blob",
            content: oldDocument.content,
            createdAt: Date(timeIntervalSince1970: 1_700_008_000)
        )
        let conflict = try SyncConflict(
            path: oldPath,
            baseBlobSHA: "old-blob",
            remoteBlobSHA: "remote-old-blob",
            localContent: oldDocument.content,
            remoteContent: "This is intentionally not a task document"
        )
        let initial = try makeWorkspace(
            selection: selection,
            configuration: configuration,
            tasks: [oldDocument, currentDocument],
            pendingChanges: [pending],
            conflicts: [conflict]
        )
        let store = FileWorkspaceStore(rootURL: directory)
        try await store.save(initial, expectedRevision: nil)
        let service = makeService(
            store: store,
            id: oldID,
            now: Date(timeIntervalSince1970: 1_700_009_000),
            uuid: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        )

        let resolved = try await service.resolveConflict(
            selection: selection,
            path: oldPath,
            resolution: .useRemote
        )

        XCTAssertEqual(resolved.tasks, [currentDocument])
        XCTAssertTrue(resolved.pendingChanges.isEmpty)
        XCTAssertTrue(resolved.conflicts.isEmpty)
        XCTAssertEqual(resolved.revision, 1)
        let durable = try await store.load(selection: selection)
        XCTAssertEqual(durable, resolved)
    }
}

private func loadRequired(
    _ store: FileWorkspaceStore,
    selection: RepositorySelection
) async throws -> WorkspaceState {
    let workspace = try await store.load(selection: selection)
    return try XCTUnwrap(workspace)
}

private struct FixedULIDGenerator: ULIDGenerating {
    let id: TaskID

    func generate(at _: Date) throws -> TaskID {
        id
    }
}

private final class AdvancingBatchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(date: Date) {
        self.date = date
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let result = date
        date = date.addingTimeInterval(86_400)
        return result
    }
}

private struct RetryingBatchULIDGenerator: ULIDGenerating {
    let ids: [TaskID]
    let referenceDate: Date

    func generate(at date: Date) throws -> TaskID {
        let index = Int((date.timeIntervalSince(referenceDate) * 1_000).rounded())
        guard ids.indices.contains(index) else {
            throw OTodoError.conflict(message: "Exhausted fixture task IDs")
        }
        return ids[index]
    }
}

private struct CapacityLimitedWorkspaceStore: WorkspacePersisting {
    let store: FileWorkspaceStore
    let maximumTaskCount: Int

    func load(selection: RepositorySelection) async throws -> WorkspaceState? {
        try await store.load(selection: selection)
    }

    func save(_ workspace: WorkspaceState, expectedRevision: UInt64?) async throws {
        guard workspace.tasks.count <= maximumTaskCount else {
            throw OTodoError.corruptLocalState(message: "Injected storage capacity failure")
        }
        try await store.save(workspace, expectedRevision: expectedRevision)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "OTodoCore-WorkspaceTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: nil
    )
    return directory
}

private func makeSelection() throws -> RepositorySelection {
    try RepositorySelection(owner: "octo", name: "vault", branch: "main", storePath: "Todo")
}

private func makeConfiguration(
    tasksDirectory: String = "Tasks",
    obsidianLinkPrefix: String = ""
) throws -> StoreConfiguration {
    try StoreConfiguration(
        schemaVersion: 1,
        tasksDirectory: tasksDirectory,
        projectsDirectory: "Projects",
        obsidianLinkPrefix: obsidianLinkPrefix,
        defaultState: "backlog",
        states: [
            try WorkflowState(id: "backlog", name: "Backlog", isTerminal: false),
            try WorkflowState(id: "doing", name: "Doing", isTerminal: false),
            try WorkflowState(id: "done", name: "Done", isTerminal: true),
        ]
    )
}

private func makeWorkspace(
    selection: RepositorySelection,
    configuration: StoreConfiguration,
    knownProjectSlugs: [String] = ["alpha", "beta"],
    tasks: [TaskDocument] = [],
    pendingChanges: [PendingChange] = [],
    conflicts: [SyncConflict] = [],
    revision: UInt64 = 0
) throws -> WorkspaceState {
    try WorkspaceState(
        selection: selection,
        configuration: configuration,
        knownProjectSlugs: knownProjectSlugs,
        tasks: tasks,
        baseHeadCommitSHA: "base-head",
        baseRootTreeSHA: "base-tree",
        pendingChanges: pendingChanges,
        conflicts: conflicts,
        revision: revision
    )
}

private func makeDocument(
    id: TaskID,
    relativePath: String? = nil,
    name: String,
    state: String = "backlog",
    projectSlugs: [String] = [],
    tags: [String] = [],
    dueDate: CivilDate? = nil,
    dueTime: CivilTime? = nil,
    recurrence: String? = nil,
    recurrenceFrom: RecurrenceFrom? = nil,
    lastCompletedDate: CivilDate? = nil,
    extraProperties: [YAMLProperty] = [],
    body: String = "",
    blobSHA: String? = nil,
    configuration: StoreConfiguration
) throws -> TaskDocument {
    let path = relativePath ?? "\(configuration.tasksDirectory)/\(id.rawValue).md"
    let task = try TodoTask(
        id: id,
        relativePath: path,
        name: name,
        state: state,
        projectSlugs: projectSlugs,
        tags: tags,
        dueDate: dueDate,
        dueTime: dueTime,
        recurrence: recurrence,
        recurrenceFrom: recurrenceFrom,
        lastCompletedDate: lastCompletedDate,
        body: body,
        extraProperties: extraProperties
    )
    let codec = ObsidianTaskCodec()
    let content = try codec.serializeTask(task, configuration: configuration)
    let canonicalTask = try codec.parseTask(
        id: id,
        relativePath: path,
        text: content,
        configuration: configuration
    )
    return TaskDocument(task: canonicalTask, content: content, blobSHA: blobSHA)
}

private func makeService(
    store: FileWorkspaceStore,
    id: TaskID,
    now: Date,
    uuid: UUID
) -> TaskWorkspaceService {
    TaskWorkspaceService(
        persistence: store,
        taskCodec: ObsidianTaskCodec(),
        ulidGenerator: FixedULIDGenerator(id: id),
        now: { now },
        makeUUID: { uuid }
    )
}

private func repositoryPath(_ selection: RepositorySelection, _ relativePath: String) -> String {
    selection.storePath.isEmpty ? relativePath : "\(selection.storePath)/\(relativePath)"
}

private func taskID(_ rawValue: String) -> TaskID {
    do {
        return try TaskID(rawValue: rawValue)
    } catch {
        preconditionFailure("Invalid test ULID \(rawValue): \(error)")
    }
}

private func assertConflict(
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected conflict", file: file, line: line)
    } catch let error as OTodoError {
        guard case .conflict = error else {
            return XCTFail("Expected conflict, got \(error)", file: file, line: line)
        }
    } catch {
        XCTFail("Expected OTodoError.conflict, got \(error)", file: file, line: line)
    }
}

private func makeReschedulingDocuments(configuration: StoreConfiguration) throws -> [TaskDocument] {
    let ids = [
        taskID("01ARZ3NDEKTSV4RRFFQ69G5FAV"),
        taskID("01ARZ3NDEKTSV4RRFFQ69G5FAW"),
        taskID("01ARZ3NDEKTSV4RRFFQ69G5FAX"),
    ]
    let times = [try CivilTime(rawValue: "08:15"), nil, try CivilTime(rawValue: "17:45")]
    return try ids.enumerated().map { index, id in
        try makeDocument(
            id: id, name: "Task \(index)", state: index == 1 ? "doing" : "backlog",
            projectSlugs: ["alpha", "beta"], tags: ["important", "home"],
            dueDate: CivilDate(rawValue: "2027-03-0\(index + 1)"), dueTime: times[index],
            recurrence: index == 2 ? "FREQ=WEEKLY;INTERVAL=1" : nil,
            recurrenceFrom: index == 2 ? .schedule : nil,
            lastCompletedDate: index == 2 ? CivilDate(rawValue: "2027-02-24") : nil,
            extraProperties: [YAMLProperty(name: "custom", value: .string("Keep me"))],
            body: "Exact body \(index)\n\n- [ ] Checklist\n", blobSHA: "base-\(index)",
            configuration: configuration
        )
    }
}

private func assertReschedulingValidation(operation: () async throws -> Void) async {
    do {
        try await operation()
        XCTFail("Expected schedule validation failure")
    } catch let error as OTodoError {
        guard case .validation = error else {
            return XCTFail("Expected validation failure, got \(error)")
        }
    } catch {
        XCTFail("Expected validation failure, got \(error)")
    }
}
