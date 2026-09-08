import Foundation

/// Device-local timing, deliberately separate from the task's persisted due date.
public struct TaskReminderLeadTime: Sendable, Equatable {
    public enum Unit: String, Sendable {
        case minutes
        case hours
        case days
    }

    public let value: Int
    public let unit: Unit

    public static let atDueTime = TaskReminderLeadTime()
    public static let fiveMinutes = TaskReminderLeadTime(value: 5, unit: .minutes)!
    public static let oneHour = TaskReminderLeadTime(value: 1, unit: .hours)!

    public init?(value: Int, unit: Unit) {
        guard value > 0 else { return nil }
        self.value = value
        self.unit = unit
    }

    private init() {
        value = 0
        unit = .minutes
    }

    fileprivate func fireDate(before dueDate: Date, calendar: Calendar) -> Date? {
        switch unit {
        case .minutes:
            return dueDate.addingTimeInterval(-Double(value) * 60)
        case .hours:
            return dueDate.addingTimeInterval(-Double(value) * 3_600)
        case .days:
            // A calendar day is not always 24 hours at a daylight-saving boundary.
            return calendar.date(byAdding: .day, value: -value, to: dueDate)
        }
    }
}

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
    public let dueTime: CivilTime?
    public let fireDate: Date
    public let timing: TaskReminderTiming

    public init(
        identifier: String,
        taskID: TaskID,
        taskName: String,
        dueDate: CivilDate,
        dueTime: CivilTime?,
        fireDate: Date,
        timing: TaskReminderTiming
    ) {
        self.identifier = identifier
        self.taskID = taskID
        self.taskName = taskName
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.fireDate = fireDate
        self.timing = timing
    }
}

public enum TaskReminderPlanner {
    public static let identifierPrefix = "otodo.task."
    public static let maximumPendingReminders = 64

    public static func identifier(for task: TodoTask) -> String? {
        guard let dueDate = task.dueDate else { return nil }
        let timeIdentity = task.dueTime.map {
            $0.rawValue.replacingOccurrences(of: ":", with: "")
        } ?? "date"
        return "\(identifierPrefix)\(task.id.rawValue).\(dueDate.rawValue).\(timeIdentity)"
    }

    public static func reminders(
        for tasks: [TodoTask],
        states: [WorkflowState],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        defaultHour: Int = 9,
        minimumLeadTime: TimeInterval = 60,
        leadTime: TaskReminderLeadTime = .atDueTime,
        excludingIdentifiers: Set<String> = []
    ) -> [TaskReminder] {
        precondition((0 ... 23).contains(defaultHour), "defaultHour must be in 0...23")
        precondition(minimumLeadTime > 0, "minimumLeadTime must be positive")

        let terminalStateIDs = Set(states.lazy.filter(\.isTerminal).map(\.id))
        let startOfToday = calendar.startOfDay(for: now)

        return tasks.compactMap { task -> TaskReminder? in
            guard !terminalStateIDs.contains(task.state),
                  let dueDate = task.dueDate,
                  let identifier = Self.identifier(for: task),
                  !excludingIdentifiers.contains(identifier),
                  let scheduledDate = Self.scheduledDate(
                      for: dueDate,
                      time: task.dueTime,
                      defaultHour: defaultHour,
                      calendar: calendar
                  ),
                  let advancedDate = leadTime.fireDate(before: scheduledDate, calendar: calendar)
            else {
                return nil
            }

            let dueDay = calendar.startOfDay(for: scheduledDate)
            let timing: TaskReminderTiming
            if dueDay < startOfToday || (task.dueTime != nil && scheduledDate <= now) {
                timing = .overdue
            } else if dueDay == startOfToday {
                timing = .dueToday
            } else {
                timing = .upcoming
            }

            let fireDate = advancedDate > now
                ? advancedDate
                : now.addingTimeInterval(minimumLeadTime)
            return TaskReminder(
                identifier: identifier,
                taskID: task.id,
                taskName: task.name,
                dueDate: dueDate,
                dueTime: task.dueTime,
                fireDate: fireDate,
                timing: timing
            )
        }
        .sorted { lhs, rhs in
            if lhs.fireDate != rhs.fireDate {
                return lhs.fireDate < rhs.fireDate
            }
            if lhs.dueDate != rhs.dueDate {
                return lhs.dueDate < rhs.dueDate
            }
            if lhs.dueTime != rhs.dueTime {
                switch (lhs.dueTime, rhs.dueTime) {
                case let (left?, right?): return left < right
                case (nil, _?): return true
                case (_?, nil): return false
                case (nil, nil): break
                }
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
        time: CivilTime?,
        defaultHour: Int,
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
        components.hour = time?.hour ?? defaultHour
        components.minute = time?.minute ?? 0
        return calendar.date(from: components)
    }
}
