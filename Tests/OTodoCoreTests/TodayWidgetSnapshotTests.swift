import Foundation
import XCTest
@testable import OTodoCore

final class TodayWidgetSnapshotTests: XCTestCase {
    func testSnapshotKeepsActiveDatedTasksAndBuildsTodayView() throws {
        let states = [
            try WorkflowState(id: "pending", name: "Pending", isTerminal: false),
            try WorkflowState(id: "doing", name: "Doing", isTerminal: false),
            try WorkflowState(id: "done", name: "Done", isTerminal: true),
        ]
        let generatedAt = Date(timeIntervalSince1970: 1_788_508_800)
        let tasks = try [
            task(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV", name: "Overdue", state: "pending", dueDate: "2026-09-03", dueTime: "10:00"),
            task(id: "01ARZ3NDEKTSV4RRFFQ69G5FAW", name: "No time", state: "doing", dueDate: "2026-09-04"),
            task(id: "01ARZ3NDEKTSV4RRFFQ69G5FAX", name: "Morning", state: "pending", dueDate: "2026-09-04", dueTime: "09:00"),
            task(id: "01ARZ3NDEKTSV4RRFFQ69G5FAY", name: "Future", state: "pending", dueDate: "2026-09-05"),
            task(id: "01ARZ3NDEKTSV4RRFFQ69G5FAZ", name: "Undated", state: "pending"),
            task(id: "01ARZ3NDEKTSV4RRFFQ69G5FB0", name: "Completed", state: "done", dueDate: "2026-09-04"),
        ]

        let snapshot = TodayWidgetSnapshotBuilder.make(
            tasks: tasks,
            states: states,
            generatedAt: generatedAt
        )

        XCTAssertEqual(snapshot.generatedAt, generatedAt)
        XCTAssertEqual(snapshot.tasks.map(\.name), ["Overdue", "No time", "Morning", "Future"])
        XCTAssertEqual(
            snapshot.tasks(dueOnOrBefore: "2026-09-04").map(\.name),
            ["Overdue", "No time", "Morning"]
        )
    }

    func testSnapshotJSONRoundTripPreservesWidgetData() throws {
        let snapshot = TodayWidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_788_508_800),
            tasks: [
                TodayWidgetTask(
                    id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
                    name: "Call mum",
                    dueDate: "2026-09-04",
                    dueTime: "09:30"
                ),
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(TodayWidgetSnapshot.self, from: data), snapshot)
    }

    func testDateKeyUsesProvidedTimeZone() {
        let date = Date(timeIntervalSince1970: 1_788_481_800)

        XCTAssertEqual(
            TodayWidgetSnapshotBuilder.dateKey(
                for: date,
                timeZone: TimeZone(secondsFromGMT: 0)!
            ),
            "2026-09-04"
        )
        XCTAssertEqual(
            TodayWidgetSnapshotBuilder.dateKey(
                for: date,
                timeZone: TimeZone(secondsFromGMT: -8 * 60 * 60)!
            ),
            "2026-09-03"
        )
    }

    private func task(
        id rawID: String,
        name: String,
        state: String,
        dueDate: String? = nil,
        dueTime: String? = nil
    ) throws -> TodoTask {
        let id = try TaskID(rawValue: rawID)
        return try TodoTask(
            id: id,
            relativePath: "tasks/\(rawID).md",
            name: name,
            state: state,
            projectSlugs: [],
            tags: [],
            dueDate: try dueDate.map(CivilDate.init(rawValue:)),
            dueTime: try dueTime.map(CivilTime.init(rawValue:)),
            recurrence: nil,
            recurrenceFrom: nil,
            lastCompletedDate: nil,
            body: "",
            extraProperties: []
        )
    }
}
