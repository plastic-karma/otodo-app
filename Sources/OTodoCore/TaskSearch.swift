import Foundation

/// A reusable, offline query over the text users can recognize on a todo.
public struct TaskSearch: Sendable, Equatable {
    private let terms: [String]

    public var isEmpty: Bool { terms.isEmpty }

    public init(_ text: String) {
        terms = text
            .split(whereSeparator: \Character.isWhitespace)
            .map { Self.normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    public func matches(_ task: TodoTask) -> Bool {
        guard !terms.isEmpty else { return true }
        let searchableText = Self.normalize([
            task.name,
            task.body,
            task.projectSlugs.joined(separator: " "),
            task.tags.joined(separator: " "),
            task.url ?? "",
            task.id.rawValue,
        ].joined(separator: "\n"))
        return terms.allSatisfy(searchableText.contains)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
