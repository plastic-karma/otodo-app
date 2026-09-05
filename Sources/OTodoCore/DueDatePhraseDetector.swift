import Foundation

public struct DetectedDueDatePhrase: Sendable, Equatable {
    public let phrase: String
    public let dueDate: CivilDate
    public let utf16Range: NSRange
    public let nameWithoutPhrase: String
}

public enum DueDatePhraseDetector {
    public static func detect(
        in value: String,
        from referenceDate: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> DetectedDueDatePhrase? {
        let words = words(in: value)
        guard !words.isEmpty else { return nil }

        var candidate: Candidate?
        for index in words.indices {
            let word = words[index].normalized
            if word == "tomorrow" {
                candidate = Candidate(range: words[index].range, meaning: .days(1))
                continue
            }
            if let weekday = weekdayNumber(for: word) {
                candidate = Candidate(
                    range: words[index].range,
                    meaning: .weekday(weekday)
                )
                continue
            }
            if word == "next", words.indices.contains(index + 1) {
                let nextWord = words[index + 1]
                let meaning: Meaning?
                switch nextWord.normalized {
                case "week":
                    meaning = .weeks(1)
                case "month":
                    meaning = .months(1)
                default:
                    meaning = nil
                }
                if let meaning {
                    candidate = Candidate(
                        range: words[index].range.lowerBound ..< nextWord.range.upperBound,
                        meaning: meaning
                    )
                }
                continue
            }
            if word == "in", words.indices.contains(index + 2) {
                let amountWord = words[index + 1]
                let unitWord = words[index + 2]
                guard let amount = positiveInteger(amountWord.normalized) else {
                    continue
                }
                let singularUnit = unitWord.normalized.hasSuffix("s")
                    ? String(unitWord.normalized.dropLast())
                    : unitWord.normalized
                let meaning: Meaning?
                switch singularUnit {
                case "day":
                    meaning = .days(amount)
                case "week":
                    meaning = .weeks(amount)
                case "month":
                    meaning = .months(amount)
                default:
                    meaning = nil
                }
                if let meaning {
                    candidate = Candidate(
                        range: words[index].range.lowerBound ..< unitWord.range.upperBound,
                        meaning: meaning
                    )
                }
            }
        }

        guard let candidate else { return nil }
        let start = calendar.startOfDay(for: referenceDate)
        let resolvedDate: Date?
        switch candidate.meaning {
        case let .days(amount):
            resolvedDate = calendar.date(byAdding: .day, value: amount, to: start)
        case let .weeks(amount):
            resolvedDate = calendar.date(byAdding: .weekOfYear, value: amount, to: start)
        case let .months(amount):
            resolvedDate = calendar.date(byAdding: .month, value: amount, to: start)
        case let .weekday(targetWeekday):
            let currentWeekday = calendar.component(.weekday, from: start)
            let rawDistance = (targetWeekday - currentWeekday + 7) % 7
            let daysAhead = rawDistance == 0 ? 7 : rawDistance
            resolvedDate = calendar.date(byAdding: .day, value: daysAhead, to: start)
        }

        guard let resolvedDate else {
            throw resolutionError
        }
        let components = calendar.dateComponents([.year, .month, .day], from: resolvedDate)
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            throw resolutionError
        }

        return DetectedDueDatePhrase(
            phrase: String(value[candidate.range]),
            dueDate: try CivilDate(
                rawValue: String(format: "%04d-%02d-%02d", year, month, day)
            ),
            utf16Range: NSRange(candidate.range, in: value),
            nameWithoutPhrase: removingPhrase(from: value, in: candidate.range)
        )
    }

    private struct Word {
        let normalized: String
        let range: Range<String.Index>
    }

    private struct Candidate {
        let range: Range<String.Index>
        let meaning: Meaning
    }

    private enum Meaning {
        case days(Int)
        case weeks(Int)
        case months(Int)
        case weekday(Int)
    }

    private static func words(in value: String) -> [Word] {
        var result: [Word] = []
        result.reserveCapacity(min(12, value.count / 3))

        var wordStart: String.Index?
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character.isLetter || character.isNumber {
                if wordStart == nil {
                    wordStart = index
                }
            } else if let start = wordStart {
                result.append(
                    Word(
                        normalized: value[start ..< index].lowercased(),
                        range: start ..< index
                    )
                )
                wordStart = nil
            }
            index = value.index(after: index)
        }
        if let start = wordStart {
            result.append(
                Word(
                    normalized: value[start ..< value.endIndex].lowercased(),
                    range: start ..< value.endIndex
                )
            )
        }
        return result
    }

    private static func positiveInteger(_ value: String) -> Int? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let amount = Int(value),
              amount > 0
        else {
            return nil
        }
        return amount
    }

    private static func weekdayNumber(for value: String) -> Int? {
        switch value {
        case "sunday", "sun":
            1
        case "monday", "mon":
            2
        case "tuesday", "tue", "tues":
            3
        case "wednesday", "wed":
            4
        case "thursday", "thu", "thur", "thurs":
            5
        case "friday", "fri":
            6
        case "saturday", "sat":
            7
        default:
            nil
        }
    }

    private static func removingPhrase(
        from value: String,
        in range: Range<String.Index>
    ) -> String {
        var prefix = value[..<range.lowerBound]
        while let last = prefix.last, last.isWhitespace || last.isPunctuation {
            prefix = prefix.dropLast()
        }

        var suffix = value[range.upperBound...]
        while let first = suffix.first, first.isWhitespace || first.isPunctuation {
            suffix = suffix.dropFirst()
        }

        if prefix.isEmpty {
            return String(suffix)
        }
        if suffix.isEmpty {
            return String(prefix)
        }
        return "\(prefix) \(suffix)"
    }

    private static var resolutionError: OTodoError {
        OTodoError.validation(
            field: "dueDatePhrase",
            message: "The detected due date is outside the supported calendar range"
        )
    }
}
