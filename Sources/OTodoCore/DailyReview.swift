import Foundation

public enum DailyReviewKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case morning
    case evening

    public var id: String { rawValue }
    public var defaultMinute: Int { self == .morning ? 8 * 60 : 20 * 60 }
    public var minuteWindow: Range<Int> { self == .morning ? (4 * 60)..<(14 * 60) : (14 * 60)..<(24 * 60) }
}

public struct DailyReviewPreference: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var minuteOfDay: Int
    public var reviewedDays: Set<String>

    public init(kind: DailyReviewKind) {
        isEnabled = false
        minuteOfDay = kind.defaultMinute
        reviewedDays = []
    }

    public func isDue(kind: DailyReviewKind, at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return isEnabled && kind.minuteWindow.contains(minute)
            && minute >= max(kind.minuteWindow.lowerBound, min(minuteOfDay, kind.minuteWindow.upperBound - 1))
            && !reviewedDays.contains(DailyReviewContext.day(at: date, calendar: calendar))
    }
}

public enum DailyReviewContext {
    public static func day(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        TodayWidgetSnapshotBuilder.dateKey(for: date, timeZone: calendar.timeZone)
    }

    public static func workspaceKey(_ selection: RepositorySelection) -> String {
        FileWorkspaceStore.selectionKey(for: selection)
    }
}

public struct DailyReviewSummary: Sendable {
    public let day: String
    public let dueToday: [TodoTask]
    public let overdue: [TodoTask]
    public let completedTasks: [TodoTask]
    public let completedOccurrences: Int

    public init(tasks: [TodoTask], terminalStateIDs: Set<String>, at date: Date, calendar: Calendar = .autoupdatingCurrent) {
        let dayKey = DailyReviewContext.day(at: date, calendar: calendar)
        day = dayKey
        let sections = TaskAgenda.sections(
            tasks: tasks, terminalStateIDs: terminalStateIDs,
            dates: TaskDateContext(referenceDate: date, calendar: calendar)
        )
        dueToday = sections.first(where: { $0.group == .today })?.tasks ?? []
        overdue = sections.first(where: { $0.group == .overdue })?.tasks ?? []
        var completed: [TodoTask] = []
        var occurrences = 0
        for task in tasks {
            let count = TaskCompletionHistory.read(task).events.reduce(into: 0) {
                if $1.completedOn.rawValue == dayKey { $0 += 1 }
            }
            if count > 0 { completed.append(task); occurrences += count }
        }
        completedTasks = completed.sorted { $0.id < $1.id }
        completedOccurrences = occurrences
    }

    public var actionableTasks: [TodoTask] {
        (overdue + dueToday).sorted {
            if $0.dueDate != $1.dueDate { return ($0.dueDate?.rawValue ?? "") < ($1.dueDate?.rawValue ?? "") }
            if $0.dueTime != $1.dueTime { return ($0.dueTime?.rawValue ?? "") < ($1.dueTime?.rawValue ?? "") }
            return $0.id < $1.id
        }
    }
}

/// A stable deck tracks occurrences, not mutable task-array positions. Content is always read live.
public struct DailyReviewSession: Codable, Sendable {
    public struct TaskReference: Codable, Sendable {
        public let id: TaskID
        private let dueDate: CivilDate?
        private let dueTime: CivilTime?
        private let completionIDs: Set<String>

        public init(task: TodoTask) {
            id = task.id
            dueDate = task.dueDate
            dueTime = task.dueTime
            completionIDs = Set(TaskCompletionHistory.read(task).events.map(\.id))
        }

        public func matchesOccurrence(_ task: TodoTask) -> Bool {
            task.id == id && task.dueDate == dueDate && task.dueTime == dueTime
                && Set(TaskCompletionHistory.read(task).events.map(\.id)) == completionIDs
        }
    }

    public enum Resolution: String, Codable, Sendable {
        case completed
        case rescheduled
    }

    public let day: String
    public let tasks: [TaskReference]
    public var page: Int
    public var resolutions: [String: Resolution]
    public var pageCount: Int { tasks.count + 3 }

    public init(summary: DailyReviewSummary) {
        day = summary.day
        tasks = summary.actionableTasks.map(TaskReference.init)
        page = 0
        resolutions = [:]
    }
}
