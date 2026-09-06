import Foundation

/// Converts shared content into a task title and lossless Markdown context without inferring dates.
public struct TaskCapture: Sendable, Equatable {
    public let name: String
    public let body: String

    public init(text: String? = nil, sourceTitle: String? = nil, sourceURL: URL? = nil) throws {
        let text = Self.nonempty(text)
        let sourceTitle = Self.nonempty(sourceTitle)
        let sourceLink = Self.nonempty(sourceURL?.absoluteString)
        guard let name = Self.firstLine(sourceTitle) ?? Self.firstLine(text) ?? sourceLink else {
            throw OTodoError.validation(
                field: "name",
                message: "Share text or a URL to create a todo"
            )
        }
        self.name = name

        var context: [String] = []
        if let sourceTitle {
            context.append(sourceTitle)
        }
        if let text, text != sourceTitle {
            context.append(text)
        }
        if let sourceLink {
            // Autolinks preserve URL punctuation without Markdown label/target escaping.
            context.append("Source: <\(sourceLink)>")
        }
        self.body = context.joined(separator: "\n\n")
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func firstLine(_ value: String?) -> String? {
        guard let value else { return nil }
        for line in value.split(whereSeparator: \.isNewline) {
            let title = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
        }
        return nil
    }
}
