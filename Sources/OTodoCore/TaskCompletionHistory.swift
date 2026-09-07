import Foundation

/// Append-only completion evidence carried in ordinary task frontmatter in either store schema.
public enum TaskCompletionHistory {
    public static let propertyName = "otodo_completion_history"

    public struct Event: Sendable, Equatable {
        public let id: String
        public let completedAt: Date
        public let completedOn: CivilDate
        public let dueDate: CivilDate?
        public let dueTime: CivilTime?
        public let onTime: Bool?
        public let projects: [String]
        public let tags: [String]
        public let usesSubtasks: Bool
        public let hasAttachments: Bool
        public let isRecurring: Bool
    }

    public struct Reading: Sendable {
        public let events: [Event]
        public let unknownEntries: Int
    }

    public static func read(_ task: TodoTask) -> Reading {
        guard let property = task.extraProperties.first(where: { $0.name == propertyName }) else {
            return Reading(events: [], unknownEntries: 0)
        }
        guard case let .sequence(values) = property.value else {
            return Reading(events: [], unknownEntries: 1)
        }
        var events: [Event] = []
        var unknown = 0
        var ids: Set<String> = []
        for value in values {
            if let event = decode(value) {
                if ids.insert(event.id).inserted { events.append(event) }
            } else {
                unknown += 1
            }
        }
        return Reading(events: events, unknownEntries: unknown)
    }

    public static func append(
        to task: inout TodoTask,
        snapshot: TodoTask,
        completedAt: Date,
        completedOn: CivilDate,
        calendar: Calendar,
        usesSubtasks: Bool,
        storePrefix: String,
        id: UUID
    ) throws {
        let index = task.extraProperties.firstIndex { $0.name == propertyName }
        var values: [YAMLValue] = []
        if let index {
            guard case let .sequence(existing) = task.extraProperties[index].value else {
                throw OTodoError.validation(
                    field: propertyName,
                    message: "Existing completion history has an unsupported format; preserve or relocate it before recording a completion"
                )
            }
            values = existing
        }
        let event = Event(
            id: id.uuidString,
            completedAt: completedAt,
            completedOn: completedOn,
            dueDate: snapshot.dueDate,
            dueTime: snapshot.dueTime,
            onTime: onTime(task: snapshot, at: completedAt, on: completedOn, calendar: calendar),
            projects: snapshot.projectSlugs,
            tags: snapshot.tags,
            usesSubtasks: usesSubtasks,
            hasAttachments: !AttachmentLinks.references(
                body: snapshot.body, taskPath: snapshot.relativePath, storePrefix: storePrefix
            ).isEmpty,
            isRecurring: snapshot.recurrence != nil
        )
        values.append(encode(event))
        let property = YAMLProperty(name: propertyName, value: .sequence(values))
        if let index { task.extraProperties[index] = property } else { task.extraProperties.append(property) }
    }

    private static func onTime(task: TodoTask, at instant: Date, on day: CivilDate, calendar: Calendar) -> Bool? {
        guard let due = task.dueDate else { return nil }
        if day != due { return day < due }
        guard let time = task.dueTime else { return true }
        // A caller-supplied historical day has no evidence of the time of day.
        guard TodayWidgetSnapshotBuilder.dateKey(for: instant, timeZone: calendar.timeZone) == day.rawValue,
              let deadline = deadline(date: due, time: time, calendar: calendar)
        else { return nil }
        return instant <= deadline
    }

    static func deadline(date: CivilDate, time: CivilTime, calendar: Calendar) -> Date? {
        let parts = date.rawValue.split(separator: "-").compactMap { Int($0) }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: time.hour, minute: time.minute
        ))
    }

    private static func encode(_ event: Event) -> YAMLValue {
        .mapping([
            YAMLProperty(name: "version", value: .integer(1)),
            YAMLProperty(name: "id", value: .string(event.id)),
            YAMLProperty(name: "completed_at_ms", value: .integer(Int64((event.completedAt.timeIntervalSince1970 * 1_000).rounded(.down)))),
            YAMLProperty(name: "completed_on", value: .string(event.completedOn.rawValue)),
            YAMLProperty(name: "due_date", value: event.dueDate.map { .string($0.rawValue) } ?? .null),
            YAMLProperty(name: "due_time", value: event.dueTime.map { .string($0.rawValue) } ?? .null),
            YAMLProperty(name: "on_time", value: event.onTime.map { .bool($0) } ?? .null),
            YAMLProperty(name: "projects", value: .sequence(event.projects.map(YAMLValue.string))),
            YAMLProperty(name: "tags", value: .sequence(event.tags.map(YAMLValue.string))),
            YAMLProperty(name: "subtasks", value: .bool(event.usesSubtasks)),
            YAMLProperty(name: "attachments", value: .bool(event.hasAttachments)),
            YAMLProperty(name: "recurring", value: .bool(event.isRecurring)),
        ])
    }

    private static func decode(_ value: YAMLValue) -> Event? {
        guard case let .mapping(properties) = value,
              Set(properties.map(\.name)).count == properties.count else { return nil }
        let fields = Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.value) })
        func strings(_ name: String) -> [String]? {
            guard case let .sequence(values) = fields[name] else { return nil }
            let strings = values.compactMap { value -> String? in
                guard case let .string(string) = value else { return nil }; return string
            }
            return strings.count == values.count ? strings : nil
        }
        guard fields["version"] == .integer(1),
              case let .string(id) = fields["id"], UUID(uuidString: id) != nil,
              case let .integer(milliseconds) = fields["completed_at_ms"],
              case let .string(day) = fields["completed_on"], let completedOn = try? CivilDate(rawValue: day),
              let projects = strings("projects"), let tags = strings("tags"),
              case let .bool(subtasks) = fields["subtasks"],
              case let .bool(attachments) = fields["attachments"],
              case let .bool(recurring) = fields["recurring"] else { return nil }
        let dueDate: CivilDate?
        switch fields["due_date"] {
        case .null: dueDate = nil
        case let .string(raw): guard let date = try? CivilDate(rawValue: raw) else { return nil }; dueDate = date
        default: return nil
        }
        let dueTime: CivilTime?
        switch fields["due_time"] {
        case .null: dueTime = nil
        case let .string(raw): guard dueDate != nil, let time = try? CivilTime(rawValue: raw) else { return nil }; dueTime = time
        default: return nil
        }
        let onTime: Bool?
        switch fields["on_time"] {
        case .null: onTime = nil
        case let .bool(value): guard dueDate != nil else { return nil }; onTime = value
        default: return nil
        }
        return Event(
            id: id, completedAt: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            completedOn: completedOn, dueDate: dueDate, dueTime: dueTime, onTime: onTime,
            projects: projects, tags: tags, usesSubtasks: subtasks, hasAttachments: attachments, isRecurring: recurring
        )
    }
}
