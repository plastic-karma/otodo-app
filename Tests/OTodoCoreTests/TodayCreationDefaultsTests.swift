import Foundation
import XCTest
@testable import OTodoCore

final class TodayCreationDefaultsTests: XCTestCase, @unchecked Sendable {
    func testBulkDefaultDatePersistsWithoutOverridingPhrasesOrLeakingToOtherViews() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = try RepositorySelection(owner: "test", name: "today", branch: "main", storePath: "")
        let configuration = try StoreConfiguration(
            schemaVersion: 2, tasksDirectory: "Tasks", projectsDirectory: "Projects", obsidianLinkPrefix: "",
            defaultState: "open", states: [WorkflowState(id: "open", name: "Open", isTerminal: false)]
        )
        let store = FileWorkspaceStore(rootURL: root)
        try await store.save(WorkspaceState(
            selection: selection, configuration: configuration, tasks: [],
            baseHeadCommitSHA: "head", baseRootTreeSHA: "tree", pendingChanges: [], conflicts: []
        ), expectedRevision: nil)
        let now = ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let service = TaskWorkspaceService(persistence: store, taskCodec: ObsidianTaskCodec(), now: { now })
        _ = try await service.addTasks(
            selection: selection, names: ["Default task", "Explicit task tomorrow"],
            defaultDueDate: CivilDate(rawValue: "2026-09-07"), calendar: calendar
        )
        _ = try await service.addTasks(selection: selection, names: ["Other view task"], calendar: calendar)
        let saved = try await FileWorkspaceStore(rootURL: root).load(selection: selection)
        let tasks = try XCTUnwrap(saved).tasks.map(\.task)
        XCTAssertEqual(try XCTUnwrap(tasks.first { $0.name == "Default task" }).dueDate?.rawValue, "2026-09-07")
        XCTAssertEqual(try XCTUnwrap(tasks.first { $0.name == "Explicit task" }).dueDate?.rawValue, "2026-09-08")
        XCTAssertNil(try XCTUnwrap(tasks.first { $0.name == "Other view task" }).dueDate)
    }
}
