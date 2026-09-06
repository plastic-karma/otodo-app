import Foundation
import XCTest
@testable import OTodoCore

final class TaskAgendaTests: XCTestCase {
    func testAgendaPartitionsActiveTasksWithoutChangingFieldsOrInputOrder() throws {
        let dates = try context("2026-09-05T12:00:00Z", timeZone: "UTC")
        let tasks = try [
            task(0, due: "2026-09-12", time: "23:59"),
            task(1, due: nil),
            task(2, due: "2026-09-04", time: "14:30"),
            task(3, due: "2026-09-06", time: "00:00"),
            task(4, due: "2026-09-05", time: "23:59"),
            task(5, due: "2026-09-13"),
            task(6, due: "2026-09-07"),
            task(7, due: "2026-08-31"),
            task(8, due: "2026-09-05", state: "archived"),
            task(9, due: nil, state: "cancelled"),
            task(10, due: "2026-09-06", state: "done"),
        ]
        let sections = TaskAgenda.sections(
            tasks: tasks, terminalStateIDs: ["archived", "cancelled"], dates: dates
        )
        XCTAssertEqual(sections.map(\.group), [.overdue, .today, .tomorrow, .nextSevenDays, .later, .noDate])
        XCTAssertEqual(sections.map(\.tasks), [
            [tasks[2], tasks[7]], [tasks[4]], [tasks[3], tasks[10]],
            [tasks[0], tasks[6]], [tasks[5]], [tasks[1]],
        ])
        let grouped = sections.flatMap(\.tasks)
        XCTAssertEqual(Set(grouped.map(\.id)).count, grouped.count)
        XCTAssertEqual(Set(grouped.map(\.id)), Set(tasks.filter { !["archived", "cancelled"].contains($0.state) }.map(\.id)))
    }

    func testAgendaKeepsEmptySectionsAndExcludesEveryTerminalDateBucket() throws {
        let dates = try context("2026-09-05T12:00:00Z", timeZone: "UTC")
        let terminalTasks = try ["2026-09-04", "2026-09-05", "2026-09-06", "2026-09-12", "2026-09-13", nil]
            .enumerated().map { index, due in try task(index, due: due, state: "closed") }
        for tasks in [[], terminalTasks] {
            let sections = TaskAgenda.sections(tasks: tasks, terminalStateIDs: ["closed"], dates: dates)
            XCTAssertEqual(sections.map(\.group), [.overdue, .today, .tomorrow, .nextSevenDays, .later, .noDate])
            XCTAssertEqual(sections.map(\.tasks), Array(repeating: [], count: 6))
        }
    }

    func testLocalMidnightChangesTheCivilDayAndRollsAcrossYears() throws {
        let before = try context("2026-01-01T07:59:59Z", timeZone: "America/Los_Angeles")
        let after = try context("2026-01-01T08:00:00Z", timeZone: "America/Los_Angeles")
        XCTAssertEqual([before.today, before.tomorrow, before.endOfNextSevenDays], ["2025-12-31", "2026-01-01", "2026-01-07"])
        XCTAssertEqual([after.today, after.tomorrow, after.endOfNextSevenDays], ["2026-01-01", "2026-01-02", "2026-01-08"])
        let task = try task(0, due: "2025-12-31", time: "23:59")
        XCTAssertFalse(try TaskFilterQuery.overdue.matches(task, terminalStateIDs: [], dates: before))
        XCTAssertTrue(try TaskFilterQuery.overdue.matches(task, terminalStateIDs: [], dates: after))
        XCTAssertEqual(TaskAgenda.sections(tasks: [task], terminalStateIDs: [], dates: before)[1].tasks, [task])
        XCTAssertEqual(TaskAgenda.sections(tasks: [task], terminalStateIDs: [], dates: after)[0].tasks, [task])
    }

    func testRelativeBoundariesUseCalendarDaysAcrossDSTAndLeapMonth() throws {
        for (instant, today, tomorrow, end) in [
            ("2026-03-08T07:30:00Z", "2026-03-07", "2026-03-08", "2026-03-14"),
            ("2026-11-01T06:30:00Z", "2026-10-31", "2026-11-01", "2026-11-07"),
            ("2028-02-29T07:30:00Z", "2028-02-28", "2028-02-29", "2028-03-06"),
            ("2026-03-01T07:30:00Z", "2026-02-28", "2026-03-01", "2026-03-07"),
        ] {
            let dates = try context(instant, timeZone: "America/Los_Angeles")
            XCTAssertEqual([dates.today, dates.tomorrow, dates.endOfNextSevenDays], [today, tomorrow, end], instant)
        }
    }

    func testCalendarSuppliesTimeZoneButCivilDatesRemainGregorian() throws {
        let gregorian = try context("2026-09-05T23:30:00Z", timeZone: "Asia/Tokyo")
        let buddhist = try context("2026-09-05T23:30:00Z", timeZone: "Asia/Tokyo", identifier: .buddhist)
        XCTAssertEqual(gregorian, buddhist)
        XCTAssertEqual([buddhist.today, buddhist.tomorrow, buddhist.endOfNextSevenDays], ["2026-09-06", "2026-09-07", "2026-09-13"])
    }

    private func context(
        _ instant: String, timeZone: String, identifier: Calendar.Identifier = .gregorian
    ) throws -> TaskDateContext {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: timeZone))
        return TaskDateContext(
            referenceDate: try XCTUnwrap(ISO8601DateFormatter().date(from: instant)), calendar: calendar
        )
    }

    private func task(_ index: Int, due: String?, time: String? = nil, state: String = "doing") throws -> TodoTask {
        let id = try TaskID(rawValue: String(format: "01ARZ3NDEKTSV4RRFFQ69G5F%02d", index))
        return try TodoTask(
            id: id, relativePath: "tasks/\(id.rawValue).md", name: "Task \(index)", state: state,
            projectSlugs: ["work"], tags: ["focus"], dueDate: try due.map(CivilDate.init(rawValue:)),
            dueTime: try time.map(CivilTime.init(rawValue:)), recurrence: nil, recurrenceFrom: nil,
            lastCompletedDate: nil, body: "Original **Markdown** \(index)", extraProperties: []
        )
    }
}
