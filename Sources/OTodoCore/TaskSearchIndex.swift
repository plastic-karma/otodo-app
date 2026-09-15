import Foundation

/// Literal, whitespace-separated terms match across fields; every term must match.
/// The index deliberately includes terminal tasks and descendants, independent of list filters.
public struct TaskSearchIndex: Sendable {
    private struct Entry: Sendable {
        let task: TodoTask
        let text: String
    }

    private let entries: [Entry]

    public init(tasks: [TodoTask], projects: [String: TodoProject]) {
        let projectNames = projects.mapValues { Self.fold($0.name) }
        entries = tasks.map { task in
            var fields = [Self.fold(task.name), Self.fold(task.body)]
            fields.append(contentsOf: task.tags.map(Self.fold))
            for slug in task.projectSlugs {
                fields.append(Self.fold(slug))
                if let name = projectNames[slug] { fields.append(name) }
            }
            return Entry(task: task, text: fields.joined(separator: "\n"))
        }
    }

    public func tasks(matching query: String) -> [TodoTask] {
        let terms = Self.fold(query).split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return [] }
        return entries.compactMap { entry in
            terms.allSatisfy { entry.text.contains($0) } ? entry.task : nil
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
