import Foundation

/// Offline mentions in prose, with cached token boundaries in UIKit's UTF-16 coordinates.
public struct TaskTextMentions: Equatable, Sendable {
    public struct Token: Equatable, Sendable {
        public let value: String
        public let utf16Range: NSRange
        fileprivate let range: Range<String.Index>
        fileprivate let valueStart: String.Index
    }

    public struct Suggestion: Equatable, Sendable {
        public let value: String
        public let replacementRange: NSRange
        private let replacement: String
        private let source: String

        fileprivate init(value: String, marker: Character, token: Token, source: String) {
            self.value = value
            replacementRange = token.utf16Range
            replacement = String(marker) + value
            self.source = source
        }

        /// A suggestion belongs to the text snapshot that produced it, not just an equal-looking token.
        public func applying(to text: String) -> (text: String, selection: NSRange)? {
            guard text.utf8.elementsEqual(source.utf8), let range = Range(replacementRange, in: text) else { return nil }
            var result = text
            result.replaceSubrange(range, with: replacement)
            return (result, NSRange(location: replacementRange.location + replacement.utf16.count, length: 0))
        }
    }

    public let tokens: [Token]
    private let source: String
    private let marker: Character
    private let utf16Count: Int

    public init(in text: String, marker: Character) {
        source = text
        self.marker = marker
        utf16Count = text.utf16.count
        tokens = Self.tokenize(text, marker: marker)
    }

    /// Resolves complete tokens only; unknown mentions never introduce new choices.
    public func recognizedValues(from choices: [String]) -> [String] {
        var recognized: [String] = []
        for token in tokens where !token.value.isEmpty {
            guard let value = choices.first(where: { $0.compare(token.value, options: .caseInsensitive) == .orderedSame }),
                  !recognized.contains(value)
            else { continue }
            recognized.append(value)
        }
        return recognized
    }

    public func suggestions(at selection: NSRange, choices: [String]) -> [Suggestion] {
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= utf16Count, selection.length <= utf16Count - selection.location,
              let selected = Range(selection, in: source)
        else { return [] }

        for token in tokens {
            guard selected.lowerBound >= token.range.lowerBound, selected.upperBound <= token.range.upperBound
            else { continue }
            // A caret before the marker has not entered the mention yet. Selecting its marker is allowed.
            guard selection.length > 0 || selected.lowerBound >= token.valueStart else { return [] }
            let prefixEnd = max(token.valueStart, selected.lowerBound)
            let prefix = String(source[token.valueStart..<prefixEnd])
            let original = source[token.range]
            return Set(choices).sorted().compactMap { value in
                guard !value.isEmpty,
                      prefix.isEmpty || value.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
                else { return nil }
                if String(marker) + value == original,
                   selection.length == 0, selection.location == NSMaxRange(token.utf16Range) {
                    return nil
                }
                return Suggestion(value: value, marker: marker, token: token, source: source)
            }
        }
        return []
    }

    private static func tokenize(_ text: String, marker: Character) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        var offset = 0
        while index < text.endIndex {
            if text[index].isWhitespace {
                offset += utf16Length(of: text[index])
                text.formIndex(after: &index)
                continue
            }

            let segmentStart = index
            var segmentEnd = index
            var segmentLength = 0
            while segmentEnd < text.endIndex, !text[segmentEnd].isWhitespace {
                segmentLength += utf16Length(of: text[segmentEnd])
                text.formIndex(after: &segmentEnd)
            }
            // URL punctuation is not a prose boundary. Keep this bounded to a whitespace-delimited
            // segment rather than interpreting Markdown, URL paths, query strings, or authorities.
            let segment = text[segmentStart..<segmentEnd]
            let urlStart = segment.drop(while: { isBoundary($0) })
            if segment.contains("://")
                || urlStart.hasPrefix("//")
                || urlStart.range(of: "mailto:", options: [.anchored, .caseInsensitive]) != nil
                || urlStart.range(of: "www.", options: [.anchored, .caseInsensitive]) != nil {
                index = segmentEnd
                offset += segmentLength
                continue
            }

            while index < segmentEnd {
                let character = text[index]
                let next = text.index(after: index)
                guard character == marker,
                      index == text.startIndex || isBoundary(text[text.index(before: index)])
                else {
                    offset += utf16Length(of: character)
                    index = next
                    continue
                }

                let start = index
                let startOffset = offset
                let valueStart = next
                offset += utf16Length(of: character)
                index = next
                while index < segmentEnd {
                    if isLabelCharacter(text[index]) {
                        offset += utf16Length(of: text[index])
                        text.formIndex(after: &index)
                    } else if text[index] == ".", index > valueStart {
                        let afterPeriod = text.index(after: index)
                        guard afterPeriod < segmentEnd, isLabelCharacter(text[afterPeriod]) else { break }
                        offset += 1
                        index = afterPeriod
                    } else {
                        break
                    }
                }
                tokens.append(Token(
                    value: String(text[valueStart..<index]),
                    utf16Range: NSRange(location: startOffset, length: offset - startOffset),
                    range: start..<index,
                    valueStart: valueStart
                ))
            }
        }
        return tokens
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character.isWhitespace || "()[]{}<>\"'“”‘’«».,:;!?—–".contains(character)
    }

    private static func utf16Length(of character: Character) -> Int {
        character.unicodeScalars.reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }
    }

    private static func isLabelCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark:
                return true
            default:
                return scalar == "_" || scalar == "-"
            }
        }
    }
}
