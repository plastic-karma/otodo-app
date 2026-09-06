import Foundation
import XCTest
@testable import OTodoCore

final class TaskSortOrderTests: XCTestCase {
    func testDueDateKeepsAllDayBeforeTimedAndUndatedLast() throws {
        let expected = try [
            task(0, due: "2026-09-05"),
            task(1, name: "Zulu", due: "2026-09-06"),
            task(2, name: "Alpha", state: "done", due: "2026-09-06"),
            task(3, due: "2026-09-06", time: "00:00"),
            task(4, due: "2026-09-06", time: "16:00"),
            task(5, due: "2026-09-07"),
            task(6, name: "Aardvark"),
        ]
        var tasks = Array(expected.reversed())
        TaskSortOrder.dueDate.sort(&tasks, stateOrder: ["todo": 0, "done": 1])
        XCTAssertEqual(tasks.map(\.id), expected.map(\.id))
    }

    func testCreationOrderIgnoresNamesAndDeadlinesAndBreaksTimestampTies() throws {
        let oldest = try task(0, created: 1, name: "Alpha", due: "2026-09-04")
        let middle = try task(1, created: 2, name: "Zulu", due: "2026-09-05")
        let newest = try task(2, created: 3, name: "Beta")
        let sameMillisecond = try task(3, created: 3, name: "Gamma", due: "2026-09-06")
        var tasks = [oldest, sameMillisecond, middle, newest]
        TaskSortOrder.createdDate.sort(&tasks, stateOrder: [:])
        XCTAssertEqual(tasks.map(\.id), [sameMillisecond, newest, middle, oldest].map(\.id))
    }

    func testAlphabeticalIsCaseInsensitiveAndNumericWithStableTies() throws {
        let ten = try task(0, name: "alpha 10", due: "2026-09-04")
        let two = try task(1, name: "Alpha 2")
        let duplicate = try task(2, name: "alpha 2", state: "done", due: "2026-09-05")
        let last = try task(3, name: "Zulu", due: "2026-09-03")
        var tasks = [last, duplicate, ten, two]
        TaskSortOrder.alphabetical.sort(&tasks, stateOrder: ["done": 0], locale: Locale(identifier: "en_US"))
        XCTAssertEqual(tasks.map(\.id), [two, duplicate, ten, last].map(\.id))
    }

    private func task(
        _ index: Int, created: Int = 1, name: String = "Task", state: String = "todo",
        due: String? = nil, time: String? = nil
    ) throws -> TodoTask {
        let id = try TaskID(rawValue: String(format: "00000000%02d00000000000000%02d", created, index))
        return try TodoTask(
            id: id, relativePath: "tasks/\(id.rawValue).md", name: name, state: state,
            projectSlugs: [], tags: [], dueDate: try due.map(CivilDate.init(rawValue:)),
            dueTime: try time.map(CivilTime.init(rawValue:)), recurrence: nil, recurrenceFrom: nil,
            lastCompletedDate: nil, body: "", extraProperties: []
        )
    }
}
