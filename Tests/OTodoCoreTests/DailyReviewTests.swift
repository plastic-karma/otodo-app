import Foundation
import XCTest
@testable import OTodoCore

final class DailyReviewTests: XCTestCase, @unchecked Sendable {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testPromptWindowTimeAndReviewedDayAcrossMidnightAndTimeZones() {
        var preference = DailyReviewPreference(kind: .evening)
        preference.isEnabled = true
        preference.minuteOfDay = 19 * 60 + 15
        XCTAssertFalse(preference.isDue(kind: .evening, at: instant("2026-09-15T19:14:59Z"), calendar: calendar))
        XCTAssertTrue(preference.isDue(kind: .evening, at: instant("2026-09-15T19:15:00Z"), calendar: calendar))
        XCTAssertTrue(preference.isDue(kind: .evening, at: instant("2026-09-15T23:59:59Z"), calendar: calendar))
        XCTAssertFalse(preference.isDue(kind: .evening, at: instant("2026-09-16T00:00:00Z"), calendar: calendar))
        preference.reviewedDays.insert("2026-09-15")
        XCTAssertFalse(preference.isDue(kind: .evening, at: instant("2026-09-15T20:00:00Z"), calendar: calendar))
        XCTAssertTrue(preference.isDue(kind: .evening, at: instant("2026-09-16T20:00:00Z"), calendar: calendar))
        var pacific = calendar
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertFalse(preference.isDue(kind: .evening, at: instant("2026-09-16T03:00:00Z"), calendar: pacific), "Still the reviewed local day")
        XCTAssertTrue(preference.isDue(kind: .evening, at: instant("2026-09-17T03:00:00Z"), calendar: pacific))
        preference.isEnabled = false
        XCTAssertFalse(preference.isDue(kind: .evening, at: instant("2026-09-17T03:00:00Z"), calendar: pacific))
    }

    func testMorningPromptExpiresWhenEveningWindowStarts() {
        var preference = DailyReviewPreference(kind: .morning)
        preference.isEnabled = true
        preference.minuteOfDay = 6 * 60
        XCTAssertFalse(preference.isDue(kind: .morning, at: instant("2026-09-15T05:59:59Z"), calendar: calendar))
        XCTAssertTrue(preference.isDue(kind: .morning, at: instant("2026-09-15T13:59:59Z"), calendar: calendar))
        XCTAssertFalse(preference.isDue(kind: .morning, at: instant("2026-09-15T14:00:00Z"), calendar: calendar))
    }

    func testRecurringCompletionCannotBeRepeatedByReturningToSnapshotCard() throws {
        var task = try makeTask(due: "2026-09-15")
        task.recurrence = "FREQ=DAILY"
        task.recurrenceFrom = .schedule
        let summary = DailyReviewSummary(tasks: [task], terminalStateIDs: ["done"], at: instant("2026-09-15T08:00:00Z"), calendar: calendar)
        var session = DailyReviewSession(summary: summary)
        let reference = try XCTUnwrap(session.tasks.first)
        task.name = "Renamed during review"
        XCTAssertTrue(reference.matchesOccurrence(task), "Live metadata changes do not remove the occurrence")
        let snapshot = task
        try TaskCompletionHistory.append(to: &task, snapshot: snapshot,
            completedAt: instant("2026-09-15T08:01:00Z"), completedOn: CivilDate(rawValue: "2026-09-15"),
            calendar: calendar, usesSubtasks: false, storePrefix: "", id: UUID())
        XCTAssertFalse(reference.matchesOccurrence(task), "History detects a new occurrence even when its due date has not changed")
        task.dueDate = try CivilDate(rawValue: "2026-09-16")
        session.page = 2
        session.resolutions[task.id.rawValue] = .completed
        let restored = try JSONDecoder().decode(DailyReviewSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.page, 2)
        XCTAssertEqual(restored.tasks.map(\.id), [task.id], "Completed or rescheduled tasks must not shift page identity")
        XCTAssertEqual(restored.resolutions[task.id.rawValue], .completed)
        let refreshed = DailyReviewSummary(tasks: [task], terminalStateIDs: ["done"], at: instant("2026-09-15T08:02:00Z"), calendar: calendar)
        XCTAssertTrue(refreshed.actionableTasks.isEmpty)
        XCTAssertEqual(refreshed.completedTasks.map(\.id), [task.id])
        XCTAssertEqual(refreshed.completedOccurrences, 1)
    }

    func testSummaryExcludesUnknownLegacyCompletionsAndFutureWork() throws {
        var legacy = try makeTask(due: nil)
        legacy.state = "done"
        let future = try makeTask(due: "2026-09-16", id: "01ARZ3NDEKTSV4RRFFQ69G5FAY")
        let earlier = try makeTask(due: "2026-09-14", id: "01ARZ3NDEKTSV4RRFFQ69G5FAZ")
        let summary = DailyReviewSummary(tasks: [legacy, future, earlier], terminalStateIDs: ["done"], at: instant("2026-09-15T08:00:00Z"), calendar: calendar)
        XCTAssertEqual(summary.completedOccurrences, 0)
        XCTAssertEqual(summary.actionableTasks.map(\.id), [earlier.id])
    }

    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func makeTask(due: String?, id: String = "01ARZ3NDEKTSV4RRFFQ69G5FAX") throws -> TodoTask {
        let taskID = try TaskID(rawValue: id)
        return try TodoTask(id: taskID, relativePath: "Tasks/\(id).md", name: "Review task", state: "pending", projectSlugs: [], tags: [], dueDate: due.map { try CivilDate(rawValue: $0) }, recurrence: nil, recurrenceFrom: nil, lastCompletedDate: nil, body: "", extraProperties: [])
    }
}
