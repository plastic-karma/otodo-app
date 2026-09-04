import Foundation

public enum TaskReminderTiming: Sendable, Equatable {
    case overdue
    case dueToday
    case upcoming
}

public struct TaskReminder: Sendable, Equatable {
    public let identifier: String
    public let taskID: TaskID
    public let taskName: String
    public let dueDate: CivilDate
    public let fireDate: Date
    public let timing: TaskReminderTiming

    public init(
        identifier: String,
        taskID: TaskID,
        taskName: String,
        dueDate: CivilDate,
        fireDate: Date,
        timing: TaskReminderTiming
    ) {
        self.identifier = identifier
        self.taskID = taskID
        self.taskName = taskName
        self.dueDate = dueDate
        self.fireDate = fireDate
        self.timing = timing
    }
}

public enum TaskReminderPlanner {
    public static let identifierPrefix = "otodo.task."
    public static let maximumPendingReminders = 64

    public static func reminders(
        for tasks: [TodoTask],
        states: [WorkflowState],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        defaultHour: Int = 9,
        minimumLeadTime: TimeInterval = 60
    ) -> [TaskReminder] {
        precondition((0 ... 23).contains(defaultHour), "defaultHour must be in 0...23")
        precondition(minimumLeadTime > 0, "minimumLeadTime must be positive")

        let terminalStateIDs = Set(states.lazy.filter(\.isTerminal).map(\.id))
        let startOfToday = calendar.startOfDay(for: now)

        return tasks.compactMap { task -> TaskReminder? in
            guard !terminalStateIDs.contains(task.state),
                  let dueDate = task.dueDate,
                  let scheduledDate = Self.scheduledDate(
                      for: dueDate,
                      hour: defaultHour,
                      calendar: calendar
                  )
            else {
                return nil
            }

            let dueDay = calendar.startOfDay(for: scheduledDate)
            let timing: TaskReminderTiming
            if dueDay < startOfToday {
                timing = .overdue
            } else if dueDay == startOfToday {
                timing = .dueToday
            } else {
                timing = .upcoming
            }

            let fireDate = scheduledDate > now
                ? scheduledDate
                : now.addingTimeInterval(minimumLeadTime)
            return TaskReminder(
                identifier: "\(identifierPrefix)\(task.id.rawValue).\(dueDate.rawValue)",
                taskID: task.id,
                taskName: task.name,
                dueDate: dueDate,
                fireDate: fireDate,
                timing: timing
            )
        }
        .sorted { lhs, rhs in
            if lhs.dueDate != rhs.dueDate {
                return lhs.dueDate < rhs.dueDate
            }
            if lhs.taskName != rhs.taskName {
                return lhs.taskName.utf8.lexicographicallyPrecedes(rhs.taskName.utf8)
            }
            return lhs.taskID.rawValue < rhs.taskID.rawValue
        }
        .prefix(maximumPendingReminders)
        .map { $0 }
    }

    private static func scheduledDate(
        for dueDate: CivilDate,
        hour: Int,
        calendar: Calendar
    ) -> Date? {
        let parts = dueDate.rawValue.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = hour
        components.minute = 0
        return calendar.date(from: components)
    }
}
