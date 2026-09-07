import Foundation

public struct TaskStatistics: Sendable {
    public struct Ranking: Sendable, Equatable, Identifiable {
        public let name: String
        public let count: Int
        public var id: String { name }
    }

    public struct FeatureUsage: Sendable, Equatable {
        public internal(set) var subtasks = 0
        public internal(set) var attachments = 0
        public internal(set) var recurring = 0

        mutating func include(subtasks: Bool, attachments: Bool, recurring: Bool) {
            if subtasks { self.subtasks += 1 }
            if attachments { self.attachments += 1 }
            if recurring { self.recurring += 1 }
        }
    }

    public let week: DateInterval
    public private(set) var finished = 0
    public private(set) var finishedOnTime = 0
    public private(set) var assessedDatedCompletions = 0
    public private(set) var undatedCompletions = 0
    public private(set) var unassessedDatedCompletions = 0
    public private(set) var created = 0
    public private(set) var activeProjects: [Ranking] = []
    public private(set) var activeTags: [Ranking] = []
    public private(set) var currentOverdueProjects: [Ranking] = []
    public private(set) var currentOverdueTags: [Ranking] = []
    public private(set) var completedFeatureUsage = FeatureUsage()
    public private(set) var currentFeatureUsage = FeatureUsage()
    public private(set) var retainedTasks = 0
    public private(set) var legacyCompletedTasks = 0
    public private(set) var unknownHistoryEntries = 0
    public private(set) var earliestRecordedCompletion: Date?

    /// Calendar weeks use the caller's first weekday, minimum days, and time zone; the end is exclusive.
    public static func week(containing date: Date, calendar: Calendar = .autoupdatingCurrent) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date)!
    }

    public init(
        tasks: [TodoTask], configuration: StoreConfiguration,
        containing date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent
    ) {
        let interval = Self.week(containing: date, calendar: calendar)
        week = interval
        retainedTasks = tasks.count
        let terminal = Set(configuration.states.filter(\.isTerminal).map(\.id))
        let parents = Set(tasks.compactMap(\.parentID))
        let today = TodayWidgetSnapshotBuilder.dateKey(for: now, timeZone: calendar.timeZone)
        var projects: [String: Int] = [:]
        var tags: [String: Int] = [:]
        var overdueProjects: [String: Int] = [:]
        var overdueTags: [String: Int] = [:]
        func add(_ names: [String], to counts: inout [String: Int]) {
            for name in Set(names) { counts[name, default: 0] += 1 }
        }
        func inWeek(_ instant: Date) -> Bool { instant >= interval.start && instant < interval.end }

        for task in tasks {
            if inWeek(task.id.createdAt) {
                created += 1
                add(task.projectSlugs, to: &projects)
                add(task.tags, to: &tags)
            }
            currentFeatureUsage.include(
                subtasks: task.parentID != nil || parents.contains(task.id),
                attachments: !AttachmentLinks.references(
                    body: task.body, taskPath: task.relativePath, storePrefix: configuration.obsidianLinkPrefix
                ).isEmpty,
                recurring: task.recurrence != nil
            )
            if !terminal.contains(task.state), let due = task.dueDate {
                let overdue: Bool
                if let time = task.dueTime,
                   let deadline = TaskCompletionHistory.deadline(date: due, time: time, calendar: calendar) {
                    overdue = now > deadline
                } else {
                    overdue = due.rawValue < today
                }
                if overdue {
                    add(task.projectSlugs, to: &overdueProjects)
                    add(task.tags, to: &overdueTags)
                }
            }
            let history = TaskCompletionHistory.read(task)
            unknownHistoryEntries += history.unknownEntries
            if history.events.isEmpty && (terminal.contains(task.state) || task.lastCompletedDate != nil) {
                legacyCompletedTasks += 1
            }
            for event in history.events {
                earliestRecordedCompletion = min(earliestRecordedCompletion ?? event.completedAt, event.completedAt)
                guard inWeek(event.completedAt) else { continue }
                finished += 1
                if let onTime = event.onTime {
                    assessedDatedCompletions += 1
                    if onTime { finishedOnTime += 1 }
                } else if event.dueDate == nil {
                    undatedCompletions += 1
                } else {
                    unassessedDatedCompletions += 1
                }
                add(event.projects, to: &projects)
                add(event.tags, to: &tags)
                completedFeatureUsage.include(
                    subtasks: event.usesSubtasks, attachments: event.hasAttachments, recurring: event.isRecurring
                )
            }
        }
        activeProjects = Self.rank(projects)
        activeTags = Self.rank(tags)
        currentOverdueProjects = Self.rank(overdueProjects)
        currentOverdueTags = Self.rank(overdueTags)
    }

    private static func rank(_ counts: [String: Int]) -> [Ranking] {
        counts.map { Ranking(name: $0.key, count: $0.value) }.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name
        }
    }
}
