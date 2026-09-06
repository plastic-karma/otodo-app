import Foundation

/// Offline completions using the query lexer's boundaries and UIKit's UTF-16 selection coordinates.
public enum TaskFilterCompletion {
    public struct Suggestion: Equatable, Sendable {
        public let field: String
        public let value: String
        public let replacement: String
        public let replacementRange: NSRange
        private let originalToken: String

        fileprivate init(field: String, value: String, replacement: String, range: NSRange, original: String) {
            self.field = field
            self.value = value
            self.replacement = replacement
            replacementRange = range
            originalToken = original
        }

        /// Replaces the complete current value, leaving every surrounding character intact.
        /// Rejects stale suggestions; the resulting caret sits immediately after the inserted token.
        public func applying(to query: String) -> (query: String, selection: NSRange)? {
            guard let range = Range(replacementRange, in: query), query[range] == originalToken else { return nil }
            var result = query
            result.replaceSubrange(range, with: replacement)
            return (result, NSRange(location: replacementRange.location + replacement.utf16.count, length: 0))
        }
    }

    public static func suggestions(
        in query: String,
        selection: NSRange,
        projectChoices: [String],
        tagChoices: [String]
    ) -> [Suggestion] {
        guard let selected = Range(selection, in: query) else { return [] }
        let scalars = query.unicodeScalars
        var index = scalars.startIndex

        while index < scalars.endIndex {
            if isBoundary(scalars[index]) {
                scalars.formIndex(after: &index)
                continue
            }
            let start = index
            while index < scalars.endIndex, !isBoundary(scalars[index]), scalars[index] != ":" {
                scalars.formIndex(after: &index)
            }
            let word = String(scalars[start..<index])
            if index == scalars.endIndex || scalars[index] != ":" {
                if selected.lowerBound >= start, selected.upperBound <= index {
                    let prefix = String(scalars[start..<selected.lowerBound])
                    guard !prefix.isEmpty else { return [] }
                    let fields = ["project", "tag"].filter { $0.hasPrefix(prefix) }
                    return fields.flatMap { field in
                        makeSuggestions(
                            field: field, prefix: "", range: start..<index, includesField: true,
                            query: query, selection: selection,
                            choices: field == "project" ? projectChoices : tagChoices
                        )
                    }
                }
                continue
            }

            scalars.formIndex(after: &index)
            let valueStart = index
            let quoted = index < scalars.endIndex && scalars[index] == "\""
            let regex = index < scalars.endIndex && scalars[index] == "/"
                && word != "project" && word != "tag" && word != "due"
            var closingDelimiter: String.Index?
            if quoted || regex {
                let delimiter = scalars[index]
                scalars.formIndex(after: &index)
                while index < scalars.endIndex {
                    let scalar = scalars[index]
                    let current = index
                    scalars.formIndex(after: &index)
                    if scalar == "\\" {
                        if index < scalars.endIndex { scalars.formIndex(after: &index) }
                    } else if scalar == delimiter {
                        closingDelimiter = current
                        break
                    }
                }
                if regex {
                    while index < scalars.endIndex, !isBoundary(scalars[index]) {
                        scalars.formIndex(after: &index)
                    }
                }
            } else {
                while index < scalars.endIndex, !isBoundary(scalars[index]) {
                    scalars.formIndex(after: &index)
                }
            }

            if selected.lowerBound >= start, selected.upperBound <= index {
                guard word == "project" || word == "tag", selected.lowerBound >= valueStart else { return [] }
                // A quoted value must end at a lexer boundary, not in the middle of another word.
                if quoted, closingDelimiter != nil, index < scalars.endIndex, !isBoundary(scalars[index]) {
                    return []
                }
                let prefix: String
                if quoted {
                    let contentStart = scalars.index(after: valueStart)
                    let prefixEnd = max(contentStart, min(selected.lowerBound, closingDelimiter ?? index))
                    guard let decoded = decodedQuotedPrefix(String(scalars[contentStart..<prefixEnd]))
                    else { return [] }
                    prefix = decoded
                } else {
                    prefix = String(scalars[valueStart..<selected.lowerBound])
                }
                return makeSuggestions(
                    field: word, prefix: prefix, range: valueStart..<index, includesField: false,
                    query: query, selection: selection,
                    choices: word == "project" ? projectChoices : tagChoices
                )
            }
            // Selection crossing tokens must never remove a neighboring predicate or operator.
            if selected.lowerBound < index, selected.upperBound > index { return [] }
        }
        return []
    }

    private static func makeSuggestions(
        field: String, prefix: String, range: Range<String.Index>, includesField: Bool,
        query: String, selection: NSRange, choices: [String]
    ) -> [Suggestion] {
        let replacementRange = NSRange(range, in: query)
        let original = String(query[range])
        return Set(choices).sorted().compactMap { value in
            guard !value.isEmpty,
                  prefix.isEmpty || value.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
            else { return nil }
            let replacement = (includesField ? "\(field):" : "") + literal(value)
            if replacement == original, selection.length == 0, selection.location == NSMaxRange(replacementRange) {
                return nil
            }
            return Suggestion(field: field, value: value, replacement: replacement, range: replacementRange, original: original)
        }
    }

    private static func isBoundary(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar == "(" || scalar == ")" || scalar == "&" || scalar == "|" || scalar == "!"
    }

    private static func literal(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { isBoundary($0) || $0 == "\"" || $0 == "\\" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func decodedQuotedPrefix(_ source: String) -> String? {
        var value = ""
        var escaped = false
        for scalar in source.unicodeScalars {
            if escaped {
                guard scalar == "\"" || scalar == "\\" else { return nil }
                value.unicodeScalars.append(scalar)
                escaped = false
            } else if scalar == "\\" {
                escaped = true
            } else {
                value.unicodeScalars.append(scalar)
            }
        }
        return value
    }
}
