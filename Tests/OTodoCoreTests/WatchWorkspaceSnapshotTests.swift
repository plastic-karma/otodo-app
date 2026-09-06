import Foundation
import XCTest
@testable import OTodoCore

final class WatchWorkspaceSnapshotTests: XCTestCase {
    func testCachedFutureTasksRollIntoTodayWithoutPhoneUpdates() {
        let snapshot = makeSnapshot(workspaceAvailable: true)
        let firstDay = snapshot.day(on: "2026-09-06")
        XCTAssertEqual(firstDay.overdue.map(\.name), ["Earlier"])
        XCTAssertEqual(firstDay.today.map(\.name), ["Morning"])
        XCTAssertEqual(firstDay.totalCount, 2)

        let nextDay = snapshot.day(on: "2026-09-07")
        XCTAssertEqual(nextDay.overdue.map(\.name), ["Earlier", "Morning"])
        XCTAssertEqual(nextDay.today.map(\.name), ["Tomorrow"])
        XCTAssertEqual(nextDay.totalCount, 3)
    }

    func testUnavailableWorkspaceDoesNotExposeCachedTasks() {
        let day = makeSnapshot(workspaceAvailable: false).day(on: "2026-09-07")
        XCTAssertTrue(day.today.isEmpty)
        XCTAssertTrue(day.overdue.isEmpty)
        XCTAssertEqual(day.totalCount, 0)
    }

    func testUnknownWireVersionIsRejectedBeforeDecodingNewPayloadFields() {
        let data = Data(#"{"version":2,"workspaceAvailable":true,"snapshot":null}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WatchWorkspaceSnapshot.self, from: data)) { error in
            guard case OTodoError.corruptLocalState = error else {
                return XCTFail("An unsupported Watch protocol must be reported as incompatible cached state")
            }
        }
    }

    private func makeSnapshot(workspaceAvailable: Bool) -> WatchWorkspaceSnapshot {
        WatchWorkspaceSnapshot(
            snapshot: TodayWidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 1_788_652_800), tasks: [
                TodayWidgetTask(id: "earlier", name: "Earlier", dueDate: "2026-09-05", dueTime: nil),
                TodayWidgetTask(id: "morning", name: "Morning", dueDate: "2026-09-06", dueTime: "09:15"),
                TodayWidgetTask(id: "tomorrow", name: "Tomorrow", dueDate: "2026-09-07", dueTime: nil),
            ]),
            workspaceAvailable: workspaceAvailable
        )
    }
}
