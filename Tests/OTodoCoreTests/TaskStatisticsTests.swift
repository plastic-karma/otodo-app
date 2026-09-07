import Foundation
import XCTest
@testable import OTodoCore

final class TaskStatisticsTests: XCTestCase, @unchecked Sendable {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }

    func testCalendarWeekEndIsExclusiveForCreationsAndCompletions() throws {
        let start = instant("2026-09-07T00:00:00Z")
        let end = instant("2026-09-14T00:00:00Z")
        var before = try task(at: start.addingTimeInterval(-0.001))
        var first = try task(at: start)
        var next = try task(at: end)
        try record(&before, at: start.addingTimeInterval(-0.001))
        try record(&first, at: start)
        try record(&next, at: end)
        let stats = try statistics([before, first, next], at: start)
        XCTAssertEqual(stats.week, DateInterval(start: start, end: end))
        XCTAssertEqual(stats.created, 1)
        XCTAssertEqual(stats.finished, 1)
        XCTAssertEqual(try statistics([before, first, next], at: end).finished, 1)
        var sunday = calendar
        sunday.firstWeekday = 1
        XCTAssertEqual(TaskStatistics.week(containing: start, calendar: sunday).start,
                       instant("2026-09-06T00:00:00Z"))
        var pacific = calendar
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(TaskStatistics.week(containing: instant("2026-03-05T12:00:00Z"), calendar: pacific).duration,
                       7 * 86_400 - 3_600, "Calendar weeks must follow the daylight-saving boundary")
    }

    func testExactTimeLatenessAndUndatedDenominator() throws {
        let deadline = instant("2026-09-07T14:35:00Z")
        var exact = try task(at: deadline, due: "2026-09-07", time: "14:35")
        var late = try task(at: deadline, due: "2026-09-07", time: "14:35")
        var dateOnly = try task(at: deadline, due: "2026-09-07")
        var undated = try task(at: deadline)
        try record(&exact, at: deadline)
        try record(&late, at: deadline.addingTimeInterval(0.001))
        try record(&dateOnly, at: instant("2026-09-07T23:59:59Z"))
        try record(&undated, at: deadline)
        let stats = try statistics([exact, late, dateOnly, undated], at: deadline)
        XCTAssertEqual(stats.finished, 4)
        XCTAssertEqual(stats.finishedOnTime, 2)
        XCTAssertEqual(stats.assessedDatedCompletions, 3)
        XCTAssertEqual(stats.undatedCompletions, 1)
    }

    func testCompletionSnapshotsKeepRankingsAndFeatureUsageAfterMetadataChanges() throws {
        let now = instant("2026-09-07T18:00:00Z")
        var value = try task(at: instant("2026-08-01T00:00:00Z"), due: "2026-09-07", time: "17:00")
        value.projectSlugs = ["alpha"]
        value.tags = ["focus"]
        value.body = "[Design](../Attachments/design.pdf)\n`![not an attachment](../Attachments/ignored.png)`"
        value.recurrence = "FREQ=DAILY"
        value.recurrenceFrom = .schedule
        try record(&value, at: now, subtasks: true)
        value.projectSlugs = ["beta"]
        value.tags = ["later"]
        value.body = ""
        value.recurrence = nil
        value.recurrenceFrom = nil
        let stats = try statistics([value], at: now)
        XCTAssertEqual(stats.activeProjects.map(\.name), ["alpha"])
        XCTAssertEqual(stats.activeTags.map(\.name), ["focus"])
        XCTAssertEqual(stats.currentOverdueProjects.map(\.name), ["beta"])
        XCTAssertEqual(stats.currentOverdueTags.map(\.name), ["later"])
        XCTAssertEqual(stats.completedFeatureUsage.subtasks, 1)
        XCTAssertEqual(stats.completedFeatureUsage.attachments, 1)
        XCTAssertEqual(stats.completedFeatureUsage.recurring, 1)
        XCTAssertEqual(stats.currentFeatureUsage.attachments, 0)
        XCTAssertEqual(stats.finishedOnTime, 0)
    }

    func testUnknownLegacyAndFutureHistoryArePreservedWithoutBackfill() throws {
        let now = instant("2026-09-07T18:00:00Z")
        var legacy = try task(at: now)
        legacy.state = "done"
        let future: YAMLValue = .mapping([YAMLProperty(name: "version", value: .integer(99))])
        legacy.extraProperties = [
            YAMLProperty(name: "custom", value: .string("keep")),
            YAMLProperty(name: TaskCompletionHistory.propertyName, value: .sequence([future])),
        ]
        let before = try statistics([legacy], at: now)
        XCTAssertEqual(before.finished, 0)
        XCTAssertEqual(before.legacyCompletedTasks, 1)
        XCTAssertEqual(before.unknownHistoryEntries, 1)
        XCTAssertNil(before.earliestRecordedCompletion)
        try record(&legacy, at: now)
        XCTAssertEqual(try statistics([legacy], at: now).finished, 1)
        XCTAssertEqual(TaskCompletionHistory.read(legacy).unknownEntries, 1)
        XCTAssertEqual(legacy.extraProperties.first?.value, .string("keep"))
        guard case let .sequence(entries) = legacy.extraProperties[1].value else { return XCTFail("Missing retained history") }
        XCTAssertEqual(entries.first, future)
        legacy.extraProperties[1] = YAMLProperty(name: TaskCompletionHistory.propertyName, value: .string("foreign data"))
        let unchanged = legacy
        XCTAssertThrowsError(try record(&legacy, at: now))
        XCTAssertEqual(legacy, unchanged)
    }

    func testDurableOccurrencesManualTransitionsReopenAndTerminalCreationInBothSchemas() async throws {
        for schema in [1, 2] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let selection = try RepositorySelection(owner: "test", name: "stats", branch: "main", storePath: "Todo")
            let config = try configuration(schema: schema)
            let store = FileWorkspaceStore(rootURL: root)
            try await store.save(WorkspaceState(
                selection: selection, configuration: config, knownProjectSlugs: ["alpha", "beta"], tasks: [],
                baseHeadCommitSHA: "head", baseRootTreeSHA: "tree", pendingChanges: [], conflicts: []
            ), expectedRevision: nil)
            let now = instant("2026-09-07T18:00:00Z")
            let service = TaskWorkspaceService(persistence: store, taskCodec: ObsidianTaskCodec(), now: { now }, calendar: calendar)
            let original = try await service.addTask(
                selection: selection, name: "Repeat", projectSlugs: ["alpha"], tags: ["focus"],
                dueDate: CivilDate(rawValue: "2026-09-07"), dueTime: CivilTime(rawValue: "17:00"),
                recurrence: "FREQ=DAILY", recurrenceFrom: .schedule
            )
            var current = try await service.completeTask(selection: selection, expectedTask: original, completedOn: CivilDate(rawValue: "2026-09-07"))
            current = try await service.completeTask(selection: selection, expectedTask: current, completedOn: CivilDate(rawValue: "2026-09-07"))
            XCTAssertEqual(current.dueDate, try CivilDate(rawValue: "2026-09-09"))
            let firstEvents = TaskCompletionHistory.read(current).events
            XCTAssertEqual(firstEvents.map(\.onTime), [false, true])
            var update = TaskUpdate(task: current)
            update.state = "done" // Finish series, while changing its next due date.
            update.dueDate = try CivilDate(rawValue: "2026-08-01")
            current = try await service.editTask(selection: selection, id: current.id, expectedTask: current, update: update)
            update = TaskUpdate(task: current)
            update.name = "Renamed after finishing"
            current = try await service.editTask(selection: selection, id: current.id, expectedTask: current, update: update)
            XCTAssertEqual(TaskCompletionHistory.read(current).events.count, 3, "A terminal metadata edit is not a completion")
            XCTAssertEqual(TaskCompletionHistory.read(current).events.last?.onTime, true, "Finish uses the pre-edit schedule")
            update = TaskUpdate(task: current)
            update.state = "pending"
            current = try await service.editTask(selection: selection, id: current.id, expectedTask: current, update: update)
            XCTAssertEqual(Array(TaskCompletionHistory.read(current).events.prefix(2)), firstEvents)
            update = TaskUpdate(task: current)
            update.state = "done"
            current = try await service.editTask(selection: selection, id: current.id, expectedTask: current, update: update)
            let terminal = try await service.addTask(selection: selection, name: "Already finished", state: "done")
            let loaded = try await TaskWorkspaceService(persistence: FileWorkspaceStore(rootURL: root), taskCodec: ObsidianTaskCodec()).loadWorkspace(selection: selection)
            let stats = TaskStatistics(tasks: loaded.tasks.map(\.task), configuration: config, containing: now, now: now, calendar: calendar)
            XCTAssertEqual(stats.finished, 5)
            XCTAssertEqual(stats.created, 2)
            XCTAssertEqual(stats.finishedOnTime, 2)
            XCTAssertEqual(stats.assessedDatedCompletions, 4)
            XCTAssertEqual(stats.legacyCompletedTasks, 0)
            XCTAssertEqual(stats.activeProjects.first?.count, 5, "One creation plus four completions")
            for task in [current, terminal] {
                let content = try XCTUnwrap(loaded.pendingChanges.first { $0.path == "Todo/\(task.relativePath)" }?.content)
                let synced = try ObsidianTaskCodec().parseTask(id: task.id, relativePath: task.relativePath, text: content, configuration: config)
                XCTAssertEqual(TaskCompletionHistory.read(synced).events, TaskCompletionHistory.read(task).events)
            }
        }
    }

    func testAttachmentUsageUsesVaultPrefixRatherThanRepositoryStorePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = try RepositorySelection(owner: "test", name: "stats", branch: "main", storePath: "repository/store")
        let config = try configuration(prefix: "Vault/Todos")
        let store = FileWorkspaceStore(rootURL: root)
        try await store.save(WorkspaceState(
            selection: selection, configuration: config, tasks: [],
            baseHeadCommitSHA: "head", baseRootTreeSHA: "tree", pendingChanges: [], conflicts: []
        ), expectedRevision: nil)
        let now = instant("2026-09-07T12:00:00Z")
        let service = TaskWorkspaceService(persistence: store, taskCodec: ObsidianTaskCodec(), now: { now }, calendar: calendar)
        let body = "![[Vault/Todos/Attachments/chart.png]]"
        _ = try await service.addTask(selection: selection, name: "Already finished", state: "done", body: body)
        let pending = try await service.addTask(selection: selection, name: "Finish next", body: body)
        _ = try await service.completeTask(selection: selection, expectedTask: pending, completedOn: CivilDate(rawValue: "2026-09-07"))
        let loaded = try await service.loadWorkspace(selection: selection)
        let stats = TaskStatistics(tasks: loaded.tasks.map(\.task), configuration: config, containing: now, now: now, calendar: calendar)
        XCTAssertEqual(stats.currentFeatureUsage.attachments, 2)
        XCTAssertEqual(stats.completedFeatureUsage.attachments, 2)
    }

    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func configuration(schema: Int = 1, prefix: String = "") throws -> StoreConfiguration {
        try StoreConfiguration(schemaVersion: schema, tasksDirectory: "Tasks", projectsDirectory: "Projects", obsidianLinkPrefix: prefix, defaultState: "pending", states: [
            WorkflowState(id: "pending", name: "Pending", isTerminal: false),
            WorkflowState(id: "done", name: "Done", isTerminal: true),
        ])
    }

    private func task(at date: Date, due: String? = nil, time: String? = nil) throws -> TodoTask {
        let id = try ULIDGenerator().generate(at: date)
        return try TodoTask(id: id, relativePath: "Tasks/\(id).md", name: "Stats task", state: "pending", projectSlugs: [], tags: [], dueDate: due.map { try CivilDate(rawValue: $0) }, dueTime: time.map { try CivilTime(rawValue: $0) }, recurrence: nil, recurrenceFrom: nil, lastCompletedDate: nil, body: "", extraProperties: [])
    }

    private func record(_ task: inout TodoTask, at date: Date, subtasks: Bool = false) throws {
        let snapshot = task
        try TaskCompletionHistory.append(to: &task, snapshot: snapshot, completedAt: date,
            completedOn: CivilDate(rawValue: TodayWidgetSnapshotBuilder.dateKey(for: date, timeZone: calendar.timeZone)),
            calendar: calendar, usesSubtasks: subtasks, storePrefix: "", id: UUID())
    }

    private func statistics(_ tasks: [TodoTask], at date: Date) throws -> TaskStatistics {
        TaskStatistics(tasks: tasks, configuration: try configuration(), containing: date, now: date, calendar: calendar)
    }
}
