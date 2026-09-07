import Foundation

public struct DetectedDueDatePhrase: Sendable, Equatable {
    public let phrases: [String]
    public let dueDate: CivilDate
    public let dueTime: CivilTime?
    public let hasExplicitDate: Bool
    public let utf16Ranges: [NSRange]
    public let nameWithoutPhrase: String

    /// A clock alone supplies today's date only when the editor has no selected date.
    public func resolvedDueDate(selectedDate: CivilDate?) -> CivilDate {
        hasExplicitDate ? dueDate : (selectedDate ?? dueDate)
    }
}

public enum DueDatePhraseDetector {
    public static func detect(
        in value: String,
        from referenceDate: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> DetectedDueDatePhrase? {
        let words = words(in: value)
        var dateCandidate: DateCandidate?
        let addressRanges = value.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains("/") || $0.contains("@") || $0.contains("=") }
            .map { $0.startIndex ..< $0.endIndex }
        var timeCandidate: TimeCandidate?
        for index in words.indices {
            let word = words[index].normalized
            guard !addressRanges.contains(where: { $0.overlaps(words[index].range) }) else { continue }
            if word == "today" || word == "tod" {
                dateCandidate = DateCandidate(range: words[index].range, meaning: .days(0))
            } else if word == "tomorrow" {
                dateCandidate = DateCandidate(range: words[index].range, meaning: .days(1))
            } else if let weekday = weekdayNumber(for: word) {
                dateCandidate = DateCandidate(range: words[index].range, meaning: .weekday(weekday))
            } else if word == "next", words.indices.contains(index + 1),
                      isWhitespace(value[words[index].range.upperBound ..< words[index + 1].range.lowerBound]) {
                let nextWord = words[index + 1]
                let meaning: Meaning?
                switch nextWord.normalized {
                case "week": meaning = .weeks(1)
                case "month": meaning = .months(1)
                default: meaning = nil
                }
                if let meaning {
                    dateCandidate = DateCandidate(
                        range: words[index].range.lowerBound ..< nextWord.range.upperBound,
                        meaning: meaning
                    )
                }
            } else if word == "in", words.indices.contains(index + 2) {
                let amountWord = words[index + 1]
                let unitWord = words[index + 2]
                guard isWhitespace(value[words[index].range.upperBound ..< amountWord.range.lowerBound]),
                      isWhitespace(value[amountWord.range.upperBound ..< unitWord.range.lowerBound]),
                      !addressRanges.contains(where: { $0.overlaps(amountWord.range) || $0.overlaps(unitWord.range) }),
                      let amount = positiveInteger(amountWord.normalized)
                else { continue }
                let range = words[index].range.lowerBound ..< unitWord.range.upperBound
                let singularUnit = unitWord.normalized.hasSuffix("s")
                    ? String(unitWord.normalized.dropLast()) : unitWord.normalized
                let meaning: Meaning?
                switch singularUnit {
                case "day": meaning = .days(amount)
                case "week": meaning = .weeks(amount)
                case "month": meaning = .months(amount)
                case "hour", "minute":
                    let resolved = try RelativeDueDateExpression(String(value[range])).resolve(
                        from: referenceDate, calendar: calendar
                    )
                    meaning = .resolved(resolved.date)
                    timeCandidate = TimeCandidate(range: range, time: resolved.time)
                default: meaning = nil
                }
                if let meaning {
                    dateCandidate = DateCandidate(range: range, meaning: meaning)
                }
            }
        }

        // The last explicit value wins independently for date and time, just as dates did
        // before clock recognition. Earlier phrases remain ordinary name text unless
        // they still contribute the other component (a relative hour/minute expression).
        for match in clockCandidates.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let clockRange = Range(match.range, in: value),
                  !addressRanges.contains(where: { $0.overlaps(clockRange) }),
                  let time = try clockTime(String(value[clockRange]))
            else { continue }
            var range = clockRange
            if let previous = words.last(where: { $0.range.upperBound <= clockRange.lowerBound }),
               previous.normalized == "at",
               isWhitespace(value[previous.range.upperBound ..< clockRange.lowerBound]) {
                range = previous.range.lowerBound ..< clockRange.upperBound
            }
            if timeCandidate == nil || range.lowerBound > timeCandidate!.range.lowerBound {
                timeCandidate = TimeCandidate(range: range, time: time)
            }
        }
        guard dateCandidate != nil || timeCandidate != nil else { return nil }
        let dueDate = try resolve(dateCandidate?.meaning ?? .days(0), from: referenceDate, calendar: calendar)
        var ranges = [dateCandidate?.range, timeCandidate?.range].compactMap { $0 }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        if ranges.count == 2, ranges[0] == ranges[1] { ranges.removeLast() }
        return DetectedDueDatePhrase(
            phrases: ranges.map { String(value[$0]) },
            dueDate: dueDate,
            dueTime: timeCandidate?.time,
            hasExplicitDate: dateCandidate != nil,
            utf16Ranges: ranges.map { NSRange($0, in: value) },
            nameWithoutPhrase: removingPhrases(from: value, ranges: ranges)
        )
    }

    private struct Word {
        let normalized: String
        let range: Range<String.Index>
    }

    private struct DateCandidate {
        let range: Range<String.Index>
        let meaning: Meaning
    }

    private struct TimeCandidate {
        let range: Range<String.Index>
        let time: CivilTime
    }

    private enum Meaning {
        case days(Int)
        case weeks(Int)
        case months(Int)
        case weekday(Int)
        case resolved(CivilDate)
    }

    // Match the entire clock-like token before validating it, so invalid fields cannot
    // fall back to a valid suffix (25:30, 12:345, 09:30:00, or 13:00 pm).
    // URL/path, signed-number, identifier, and decimal boundaries are not clocks.
    private static let clockCandidates = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}_:/\.\-+@#])(?:[0-9]+(?::[0-9]+)+(?:[ \t]*[ap]m[\p{L}\p{N}_]*)?|[0-9]+[ \t]*[ap]m[\p{L}\p{N}_]*)(?![\p{L}\p{N}_:/\-+@#]|\.[\p{L}\p{N}])"#
    )
    private static let validClock = try! NSRegularExpression(
        pattern: #"(?i)\A(?:([0-9]{2}):([0-9]{2})|([0-9]{1,2})(?::([0-9]{2}))?[ \t]*(am|pm))\z"#
    )

    private static func clockTime(_ value: String) throws -> CivilTime? {
        let string = value as NSString
        guard let match = validClock.firstMatch(in: value, range: NSRange(location: 0, length: string.length)) else {
            return nil
        }
        let hour: Int
        let minute: Int
        if match.range(at: 1).location != NSNotFound {
            hour = Int(string.substring(with: match.range(at: 1)))!
            minute = Int(string.substring(with: match.range(at: 2)))!
            guard hour < 24, minute < 60 else { return nil }
        } else {
            let rawHour = Int(string.substring(with: match.range(at: 3)))!
            minute = match.range(at: 4).location == NSNotFound
                ? 0 : Int(string.substring(with: match.range(at: 4)))!
            guard (1 ... 12).contains(rawHour), minute < 60 else { return nil }
            let isPM = string.substring(with: match.range(at: 5)).lowercased() == "pm"
            hour = rawHour % 12 + (isPM ? 12 : 0)
        }
        return try CivilTime(rawValue: String(format: "%02d:%02d", hour, minute))
    }

    private static func resolve(_ meaning: Meaning, from referenceDate: Date, calendar: Calendar) throws -> CivilDate {
        let start = calendar.startOfDay(for: referenceDate)
        let resolvedDate: Date?
        switch meaning {
        case let .days(amount):
            resolvedDate = calendar.date(byAdding: .day, value: amount, to: start)
        case let .weeks(amount):
            resolvedDate = calendar.date(byAdding: .weekOfYear, value: amount, to: start)
        case let .months(amount):
            resolvedDate = calendar.date(byAdding: .month, value: amount, to: start)
        case let .weekday(targetWeekday):
            let currentWeekday = calendar.component(.weekday, from: start)
            let rawDistance = (targetWeekday - currentWeekday + 7) % 7
            resolvedDate = calendar.date(byAdding: .day, value: rawDistance == 0 ? 7 : rawDistance, to: start)
        case let .resolved(date):
            return date
        }
        guard let resolvedDate else { throw resolutionError }
        let components = calendar.dateComponents([.year, .month, .day], from: resolvedDate)
        guard let year = components.year, let month = components.month, let day = components.day else {
            throw resolutionError
        }
        return try CivilDate(rawValue: String(format: "%04d-%02d-%02d", year, month, day))
    }

    private static func words(in value: String) -> [Word] {
        var result: [Word] = []
        result.reserveCapacity(min(12, value.count / 3))
        var wordStart: String.Index?
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character.isLetter || character.isNumber || character == "_" {
                if wordStart == nil { wordStart = index }
            } else if let start = wordStart {
                result.append(Word(normalized: value[start ..< index].lowercased(), range: start ..< index))
                wordStart = nil
            }
            index = value.index(after: index)
        }
        if let start = wordStart {
            result.append(Word(normalized: value[start...].lowercased(), range: start ..< value.endIndex))
        }
        return result
    }

    private static func isWhitespace(_ value: Substring) -> Bool {
        !value.isEmpty && value.allSatisfy(\.isWhitespace)
    }

    private static func positiveInteger(_ value: String) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let amount = Int(value), amount > 0 else { return nil }
        return amount
    }

    private static func weekdayNumber(for value: String) -> Int? {
        switch value {
        case "sunday", "sun": 1
        case "monday", "mon": 2
        case "tuesday", "tue", "tues": 3
        case "wednesday", "wed": 4
        case "thursday", "thu", "thur", "thurs": 5
        case "friday", "fri": 6
        case "saturday", "sat": 7
        default: nil
        }
    }

    private static func removingPhrases(from value: String, ranges: [Range<String.Index>]) -> String {
        // Clean punctuation around each actual phrase as before, but derive every
        // boundary from the original string so separated phrases never erase title words.
        var removals: [Range<String.Index>] = []
        for range in ranges {
            var lower = range.lowerBound
            var upper = range.upperBound
            while lower > value.startIndex {
                let previous = value.index(before: lower)
                guard isPhraseSeparator(value[previous]) else { break }
                lower = previous
            }
            while upper < value.endIndex, isPhraseSeparator(value[upper]) {
                upper = value.index(after: upper)
            }
            if let last = removals.last, lower <= last.upperBound {
                removals[removals.count - 1] = last.lowerBound ..< max(last.upperBound, upper)
            } else {
                removals.append(lower ..< upper)
            }
        }
        var parts: [String] = []
        var cursor = value.startIndex
        for range in removals {
            let part = value[cursor ..< range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { parts.append(part) }
            cursor = range.upperBound
        }
        let suffix = value[cursor...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !suffix.isEmpty { parts.append(suffix) }
        return parts.joined(separator: " ")
    }

    private static func isPhraseSeparator(_ character: Character) -> Bool {
        // URL paths and identifier punctuation are title content, not phrase separators.
        character.isWhitespace || (character.isPunctuation && !"/\\#@_".contains(character))
    }

    private static var resolutionError: OTodoError {
        OTodoError.validation(
            field: "dueDatePhrase",
            message: "The detected due date is outside the supported calendar range"
        )
    }
}
