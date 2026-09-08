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

    @Test("Uses an exact due time when one is present")
    func usesExactDueTime() throws {
        let task = try makeTask(
            idSuffix: "07",
            name: "Timed task",
            state: "todo",
            dueDate: "2026-09-05",
            dueTime: "14:35"
        )
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
        let reminder = try #require(
            TaskReminderPlanner.reminders(
                for: [task],
                states: [state],
                now: now,
                calendar: fixedCalendar
            ).first
        )
        let expectedFireDate = try #require(
            fixedCalendar.date(
                from: DateComponents(
                    timeZone: fixedCalendar.timeZone,
                    year: 2026,
                    month: 9,
                    day: 5,
                    hour: 14,
                    minute: 35
                )
            )
        )

        let expectedTime = try CivilTime(rawValue: "14:35")
        #expect(reminder.fireDate == expectedFireDate)
        #expect(reminder.dueTime == expectedTime)
        #expect(reminder.identifier.hasSuffix(".1435"))
    }

    @Test("Treats an elapsed exact time as overdue")
    func elapsedExactTimeIsOverdue() throws {
        let task = try makeTask(
            idSuffix: "08",
            name: "Elapsed task",
            state: "todo",
            dueDate: "2026-09-05",
            dueTime: "14:35"
        )
        let state = try WorkflowState(id: "todo", name: "Pending", isTerminal: false)
        let scheduledDate = try #require(
            fixedCalendar.date(
                from: DateComponents(
                    timeZone: fixedCalendar.timeZone,
                    year: 2026,
                    month: 9,
                    day: 5,
                    hour: 14,
                    minute: 35
                )
            )
        )
        let now = scheduledDate.addingTimeInterval(3_600)
        let reminder = try #require(
            TaskReminderPlanner.reminders(
                for: [task],
                states: [state],
                now: now,
                calendar: fixedCalendar
            ).first
        )

        #expect(reminder.timing == .overdue)
        #expect(reminder.fireDate == now.addingTimeInterval(60))
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

    @Test("Calendar-day advances retain local time across both DST boundaries",
          arguments: [("2026-03-08", 3, 8, 23), ("2026-11-01", 11, 1, 25)])
    func calendarDayAdvanceAcrossDST(
        scenario: (String, Int, Int, Int)
    ) throws {
        let (dueDate, month, day, elapsedHours) = scenario
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let due = try #require(calendar.date(from: DateComponents(
            year: 2026, month: month, day: day, hour: 9
        )))
        let expected = try #require(calendar.date(from: DateComponents(
            year: 2026, month: month, day: day - 1, hour: 9
        )))
        let task = try makeTask(idSuffix: "09", name: "DST date", state: "todo", dueDate: dueDate)
        let state = try WorkflowState(id: "todo", name: "Pending", isTerminal: false)
        let now = expected.addingTimeInterval(-3_600)
        let oneDay = try #require(TaskReminderLeadTime(value: 1, unit: .days))
        let twentyFourHours = try #require(TaskReminderLeadTime(value: 24, unit: .hours))
        let dayReminder = try #require(TaskReminderPlanner.reminders(
            for: [task], states: [state], now: now, calendar: calendar,
            leadTime: oneDay
        ).first)
        let hourReminder = try #require(TaskReminderPlanner.reminders(
            for: [task], states: [state], now: now.addingTimeInterval(-3_600), calendar: calendar,
            leadTime: twentyFourHours
        ).first)

        #expect(dayReminder.fireDate == expected)
        #expect(due.timeIntervalSince(dayReminder.fireDate) == Double(elapsedHours) * 3_600)
        #expect(hourReminder.fireDate == due.addingTimeInterval(-24 * 3_600))
        #expect(dayReminder.identifier == hourReminder.identifier)
    }

    @Test("Advance reminders cross midnight without changing their due occurrence")
    func advanceAcrossMidnight() throws {
        let task = try makeTask(
            idSuffix: "10", name: "Midnight deadline", state: "todo",
            dueDate: "2026-09-05", dueTime: "00:03"
        )
        let state = try WorkflowState(id: "todo", name: "Pending", isTerminal: false)
        let now = try #require(fixedCalendar.date(from: DateComponents(
            year: 2026, month: 9, day: 4, hour: 22
        )))
        let reminder = try #require(TaskReminderPlanner.reminders(
            for: [task], states: [state], now: now, calendar: fixedCalendar,
            leadTime: .fiveMinutes
        ).first)
        let expected = try #require(fixedCalendar.date(from: DateComponents(
            year: 2026, month: 9, day: 4, hour: 23, minute: 58
        )))
        #expect(reminder.fireDate == expected)
        let dueReminder = try #require(TaskReminderPlanner.reminders(
            for: [task], states: [state], now: now, calendar: fixedCalendar
        ).first)
        #expect(reminder.identifier == dueReminder.identifier)
        #expect(TaskReminderPlanner.reminders(
            for: [task], states: [state], now: now, calendar: fixedCalendar,
            excludingIdentifiers: [reminder.identifier]
        ).isEmpty)
    }

    @Test("An exact due time less than a minute away is not delayed by catch-up timing")
    func exactDueTimeWithinCatchUpWindow() throws {
        let task = try makeTask(
            idSuffix: "11", name: "Imminent", state: "todo",
            dueDate: "2026-09-05", dueTime: "14:35"
        )
        let state = try WorkflowState(id: "todo", name: "Pending", isTerminal: false)
        let due = try #require(fixedCalendar.date(from: DateComponents(
            year: 2026, month: 9, day: 5, hour: 14, minute: 35
        )))
        let reminder = try #require(TaskReminderPlanner.reminders(
            for: [task], states: [state], now: due.addingTimeInterval(-15),
            calendar: fixedCalendar
        ).first)
        #expect(reminder.fireDate == due)
    }

    @Test("Delivered occurrences do not consume the native pending-reminder limit")
    func deliveredOccurrencesLeaveRoomForPending() throws {
        let tasks = try (1 ... 65).map { index in
            try makeTask(
                idSuffix: String(format: "%02d", index), name: String(format: "Todo %02d", index),
                state: "todo", dueDate: "2026-09-05"
            )
        }
        let state = try WorkflowState(id: "todo", name: "Pending", isTerminal: false)
        let now = try #require(fixedCalendar.date(from: DateComponents(
            year: 2026, month: 9, day: 4
        )))
        let initial = TaskReminderPlanner.reminders(
            for: tasks, states: [state], now: now, calendar: fixedCalendar
        )
        #expect(initial.count == TaskReminderPlanner.maximumPendingReminders)
        let remaining = TaskReminderPlanner.reminders(
            for: tasks, states: [state], now: now, calendar: fixedCalendar,
            leadTime: .oneHour, excludingIdentifiers: Set(initial.map(\.identifier))
        )
        #expect(remaining.map(\.taskID) == [try #require(tasks.last).id])
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
        dueDate: String?,
        dueTime: String? = nil
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
            dueTime: try dueTime.map(CivilTime.init(rawValue:)),
            recurrence: nil,
            recurrenceFrom: nil,
            lastCompletedDate: nil,
            body: "",
            extraProperties: []
        )
    }
}
