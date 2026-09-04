import Foundation
import Testing
@testable import OTodoCore

@Suite("Task reminder planning")
struct TaskReminderPlannerTests {
    @Test("Schedules active dated tasks and excludes terminal or undated tasks")
    func schedulesEligibleTasks() throws {
        let calendar = fixedCalendar
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    timeZone: calendar.timeZone,
                    year: 2026,
                    month: 9,
                    day: 4,
                    hour: 10,
                    minute: 30
                )
            )
        )
        let pending = try WorkflowState(id: "todo", name: "Pending", isTerminal: false)
        let done = try WorkflowState(id: "done", name: "Done", isTerminal: true)
        let tasks = try [
            makeTask(idSuffix: "01", name: "Tomorrow", state: "todo", dueDate: "2026-09-05"),
            makeTask(idSuffix: "02", name: "Today", state: "todo", dueDate: "2026-09-04"),
            makeTask(idSuffix: "03", name: "Overdue", state: "todo", dueDate: "2026-09-03"),
            makeTask(idSuffix: "04", name: "Completed", state: "done", dueDate: "2026-09-05"),
            makeTask(idSuffix: "05", name: "Someday", state: "todo", dueDate: nil),
        ]

        let reminders = TaskReminderPlanner.reminders(
            for: tasks,
            states: [pending, done],
            now: now,
            calendar: calendar
        )
        try #require(reminders.count == 3)
        #expect(reminders.map(\.taskName) == ["Overdue", "Today", "Tomorrow"])
        #expect(reminders.map(\.timing) == [.overdue, .dueToday, .upcoming])
        #expect(reminders[0].fireDate == now.addingTimeInterval(60))
        #expect(reminders[1].fireDate == now.addingTimeInterval(60))
        let tomorrowAtNine = try #require(
            calendar.date(
                from: DateComponents(
                    timeZone: calendar.timeZone,
                    year: 2026,
                    month: 9,
                    day: 5,
                    hour: 9
                )
            )
        )
        #expect(reminders[2].fireDate == tomorrowAtNine)
    }

    @Test("Reminder identity includes the due date")
    func identityChangesWhenDueDateChanges() throws {
        let task = try makeTask(
            idSuffix: "06",
            name: "Plan launch",
            state: "todo",
            dueDate: "2026-09-05"
        )
        var movedTask = task
        movedTask.dueDate = try CivilDate(rawValue: "2026-09-06")
        let state = try WorkflowState(id: "todo", name: "Pending", isTerminal: false)
        let now = try #require(
            fixedCalendar.date(
                from: DateComponents(
                    timeZone: fixedCalendar.timeZone,
                    year: 2026,
                    month: 9,
                    day: 4,
                    hour: 8
                )
            )
        )

        let original = try #require(
            TaskReminderPlanner.reminders(
                for: [task],
                states: [state],
                now: now,
                calendar: fixedCalendar
            ).first
        )
        let moved = try #require(
            TaskReminderPlanner.reminders(
                for: [movedTask],
                states: [state],
                now: now,
                calendar: fixedCalendar
            ).first
        )

        #expect(original.identifier != moved.identifier)
        #expect(original.identifier.hasPrefix(TaskReminderPlanner.identifierPrefix))
    }

    private var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeTask(
        idSuffix: String,
        name: String,
        state: String,
        dueDate: String?
    ) throws -> TodoTask {
        let rawID = "01ARZ3NDEKTSV4RRFFQ69G5F\(idSuffix)"
        return try TodoTask(
            id: TaskID(rawValue: rawID),
            relativePath: "tasks/\(rawID).md",
            name: name,
            state: state,
            projectSlugs: [],
            tags: [],
            dueDate: try dueDate.map(CivilDate.init(rawValue:)),
            recurrence: nil,
            recurrenceFrom: nil,
            lastCompletedDate: nil,
            body: "",
            extraProperties: []
        )
    }
}
