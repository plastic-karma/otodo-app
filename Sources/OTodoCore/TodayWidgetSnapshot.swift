import Foundation

public struct TodayWidgetTask: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let dueDate: String
    public let dueTime: String?

    public init(id: String, name: String, dueDate: String, dueTime: String?) {
        self.id = id
        self.name = name
        self.dueDate = dueDate
        self.dueTime = dueTime
    }
}

public struct TodayWidgetSnapshot: Sendable, Codable, Equatable {
    public let generatedAt: Date
    public let tasks: [TodayWidgetTask]

    public init(generatedAt: Date, tasks: [TodayWidgetTask]) {
        self.generatedAt = generatedAt
        self.tasks = tasks
    }

    public func tasks(dueOnOrBefore dateKey: String) -> [TodayWidgetTask] {
        tasks.filter { $0.dueDate <= dateKey }
    }
}

public enum TodayWidgetSnapshotBuilder {
    public static func make(
        tasks: [TodoTask],
        states: [WorkflowState],
        generatedAt: Date = .now
    ) -> TodayWidgetSnapshot {
        let stateOrder = Dictionary(
            uniqueKeysWithValues: states.enumerated().map { ($0.element.id, $0.offset) }
        )
        let terminalStates = Set(states.lazy.filter(\.isTerminal).map(\.id))

        let widgetTasks = tasks
            .filter { task in
                task.dueDate != nil && !terminalStates.contains(task.state)
            }
            .sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (left?, right?) where left != right:
                    return left < right
                default:
                    break
                }

                switch (lhs.dueTime, rhs.dueTime) {
                case let (left?, right?) where left != right:
                    return left < right
                case (nil, _?):
                    return true
                case (_?, nil):
                    return false
                default:
                    break
                }

                let lhsStateIndex = stateOrder[lhs.state] ?? Int.max
                let rhsStateIndex = stateOrder[rhs.state] ?? Int.max
                if lhsStateIndex != rhsStateIndex {
                    return lhsStateIndex < rhsStateIndex
                }

                let lhsName = lhs.name.utf8
                let rhsName = rhs.name.utf8
                if !lhsName.elementsEqual(rhsName) {
                    return lhsName.lexicographicallyPrecedes(rhsName)
                }
                return lhs.id < rhs.id
            }
            .compactMap { task -> TodayWidgetTask? in
                guard let dueDate = task.dueDate else { return nil }
                return TodayWidgetTask(
                    id: task.id.rawValue,
                    name: task.name,
                    dueDate: dueDate.rawValue,
                    dueTime: task.dueTime?.rawValue
                )
            }

        return TodayWidgetSnapshot(generatedAt: generatedAt, tasks: widgetTasks)
    }

    public static func dateKey(
        for date: Date,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year!,
            components.month!,
            components.day!
        )
    }
}
