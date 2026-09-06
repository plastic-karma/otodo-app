import Foundation

public struct TaskDateContext: Equatable, Sendable {
    public let today: String
    public let tomorrow: String
    public let endOfNextSevenDays: String

    public init(referenceDate: Date = .now, calendar: Calendar = .autoupdatingCurrent) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let start = gregorian.startOfDay(for: referenceDate)
        today = TodayWidgetSnapshotBuilder.dateKey(for: start, timeZone: gregorian.timeZone)
        tomorrow = TodayWidgetSnapshotBuilder.dateKey(
            for: gregorian.date(byAdding: .day, value: 1, to: start)!, timeZone: gregorian.timeZone
        )
        endOfNextSevenDays = TodayWidgetSnapshotBuilder.dateKey(
            for: gregorian.date(byAdding: .day, value: 7, to: start)!, timeZone: gregorian.timeZone
        )
    }
}

public enum TaskAgendaGroup: String, CaseIterable, Sendable, Equatable {
    case overdue
    case today
    case tomorrow
    case nextSevenDays = "next-seven-days"
    case later
    case noDate = "no-date"

    public var title: String {
        switch self {
        case .overdue: "Overdue"
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .nextSevenDays: "Next seven days"
        case .later: "Later"
        case .noDate: "No date"
        }
    }
}

public struct TaskAgendaSection: Equatable, Sendable {
    public let group: TaskAgendaGroup
    public let tasks: [TodoTask]

    public init(group: TaskAgendaGroup, tasks: [TodoTask]) {
        self.group = group
        self.tasks = tasks
    }
}

public enum TaskAgenda {
    public static func sections(
        tasks: [TodoTask], terminalStateIDs: Set<String>, dates: TaskDateContext
    ) -> [TaskAgendaSection] {
        let groups = TaskAgendaGroup.allCases
        var buckets = Array(repeating: [TodoTask](), count: groups.count)
        for task in tasks where !terminalStateIDs.contains(task.state) {
            let index: Int
            if let due = task.dueDate?.rawValue {
                if due < dates.today {
                    index = 0
                } else if due == dates.today {
                    index = 1
                } else if due == dates.tomorrow {
                    index = 2
                } else if due <= dates.endOfNextSevenDays {
                    index = 3
                } else {
                    index = 4
                }
            } else {
                index = 5
            }
            buckets[index].append(task)
        }
        return groups.enumerated().map { index, group in
            TaskAgendaSection(group: group, tasks: buckets[index])
        }
    }
}
