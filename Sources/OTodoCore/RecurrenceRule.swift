import Foundation

public enum RecurrenceFrequency: String, Sendable, Codable, CaseIterable, Hashable {
    case daily = "DAILY"
    case weekly = "WEEKLY"
    case monthly = "MONTHLY"
    case yearly = "YEARLY"
}

public enum RecurrenceWeekday: String, Sendable, Codable, CaseIterable, Hashable {
    case monday = "MO"
    case tuesday = "TU"
    case wednesday = "WE"
    case thursday = "TH"
    case friday = "FR"
    case saturday = "SA"
    case sunday = "SU"

    fileprivate var ordinal: Int {
        switch self {
        case .monday: 0
        case .tuesday: 1
        case .wednesday: 2
        case .thursday: 3
        case .friday: 4
        case .saturday: 5
        case .sunday: 6
        }
    }
}

public struct RecurrenceRule: Sendable, Equatable, Codable, CustomStringConvertible {
    public let frequency: RecurrenceFrequency
    public let interval: UInt64
    public let byDay: [RecurrenceWeekday]
    public let byMonthDay: [Int]
    public let byMonth: [Int]

    public init(
        frequency: RecurrenceFrequency,
        interval: UInt64 = 1,
        byDay: [RecurrenceWeekday] = [],
        byMonthDay: [Int] = [],
        byMonth: [Int] = []
    ) throws {
        guard interval > 0 else {
            throw Self.invalid("INTERVAL must be a positive integer")
        }
        guard Set(byDay).count == byDay.count else {
            throw Self.invalid("BYDAY contains a duplicate value")
        }
        guard Set(byMonthDay).count == byMonthDay.count,
              byMonthDay.allSatisfy({ (1 ... 31).contains($0) })
        else {
            throw Self.invalid("BYMONTHDAY values must be unique integers from 1 through 31")
        }
        guard Set(byMonth).count == byMonth.count,
              byMonth.allSatisfy({ (1 ... 12).contains($0) })
        else {
            throw Self.invalid("BYMONTH values must be unique integers from 1 through 12")
        }
        guard byDay.isEmpty || frequency == .weekly else {
            throw Self.invalid("BYDAY is allowed only with FREQ=WEEKLY")
        }
        guard byMonthDay.isEmpty || frequency == .monthly || frequency == .yearly else {
            throw Self.invalid("BYMONTHDAY is allowed only with FREQ=MONTHLY or FREQ=YEARLY")
        }
        guard byMonth.isEmpty || frequency == .yearly else {
            throw Self.invalid("BYMONTH is allowed only with FREQ=YEARLY")
        }

        self.frequency = frequency
        self.interval = interval
        self.byDay = byDay.sorted { $0.ordinal < $1.ordinal }
        self.byMonthDay = byMonthDay.sorted()
        self.byMonth = byMonth.sorted()
    }

    public init(parsing source: String) throws {
        guard !source.isEmpty else {
            throw Self.invalid("Recurrence rule cannot be empty")
        }

        var frequency: RecurrenceFrequency?
        var interval: UInt64 = 1
        var byDay: [RecurrenceWeekday] = []
        var byMonthDay: [Int] = []
        var byMonth: [Int] = []
        var clauses: Set<String> = []

        for clause in source.split(separator: ";", omittingEmptySubsequences: false) {
            let pieces = clause.split(separator: "=", omittingEmptySubsequences: false)
            guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else {
                throw Self.invalid("Recurrence clause \"\(clause)\" must contain one nonempty '=' value")
            }
            let name = String(pieces[0]).uppercased()
            let value = String(pieces[1]).uppercased()
            guard clauses.insert(name).inserted else {
                throw Self.invalid("Recurrence clause \(name) appears more than once")
            }

            switch name {
            case "FREQ":
                guard let parsed = RecurrenceFrequency(rawValue: value) else {
                    throw Self.invalid("Unsupported recurrence frequency \"\(value)\"")
                }
                frequency = parsed
            case "INTERVAL":
                guard value.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                      let parsed = UInt64(value), parsed > 0
                else {
                    throw Self.invalid("INTERVAL must be a positive integer")
                }
                interval = parsed
            case "BYDAY":
                byDay = try Self.parseUniqueList(value, clause: "BYDAY") { item in
                    guard let weekday = RecurrenceWeekday(rawValue: item) else {
                        throw Self.invalid(
                            "Unsupported BYDAY value \"\(item)\"; ordinal weekdays are not supported"
                        )
                    }
                    return weekday
                }
            case "BYMONTHDAY":
                byMonthDay = try Self.parseNumberList(value, range: 1 ... 31, clause: "BYMONTHDAY")
            case "BYMONTH":
                byMonth = try Self.parseNumberList(value, range: 1 ... 12, clause: "BYMONTH")
            default:
                throw Self.invalid("Unsupported recurrence clause \(name)")
            }
        }

        guard let frequency else {
            throw Self.invalid("FREQ is required")
        }
        try self.init(
            frequency: frequency,
            interval: interval,
            byDay: byDay,
            byMonthDay: byMonthDay,
            byMonth: byMonth
        )
    }

    public static func parse(_ source: String) throws -> RecurrenceRule {
        try RecurrenceRule(parsing: source)
    }

    public var description: String {
        var clauses = ["FREQ=\(frequency.rawValue)", "INTERVAL=\(interval)"]
        if !byDay.isEmpty {
            clauses.append("BYDAY=\(byDay.map(\.rawValue).joined(separator: ","))")
        }
        if !byMonthDay.isEmpty {
            clauses.append("BYMONTHDAY=\(byMonthDay.map(String.init).joined(separator: ","))")
        }
        if !byMonth.isEmpty {
            clauses.append("BYMONTH=\(byMonth.map(String.init).joined(separator: ","))")
        }
        return clauses.joined(separator: ";")
    }

    /// Checks the selection clauses that constrain the current occurrence.
    /// Interval alignment is anchored by that same current occurrence and therefore
    /// cannot invalidate it.
    public func matches(_ date: CivilDate) -> Bool {
        let components = Self.dateComponents(date)
        switch frequency {
        case .daily:
            return true
        case .weekly:
            return byDay.isEmpty || byDay.contains(Self.weekday(components))
        case .monthly:
            return byMonthDay.isEmpty || byMonthDay.contains(components.day)
        case .yearly:
            return (byMonth.isEmpty || byMonth.contains(components.month)) &&
                (byMonthDay.isEmpty || byMonthDay.contains(components.day))
        }
    }

    /// Advances one record, skipping missed occurrences rather than creating catch-up tasks.
    public func nextDue(
        currentDue: CivilDate,
        completedOn: CivilDate,
        mode: RecurrenceFrom
    ) throws -> CivilDate {
        guard interval > 0 else {
            throw Self.invalid("INTERVAL must be a positive integer")
        }
        let anchor = Self.dateComponents(mode == .schedule ? currentDue : completedOn)
        let threshold = Self.dateComponents(mode == .schedule ? max(currentDue, completedOn) : completedOn)
        let anchorDay = Self.dayIndex(anchor)
        let thresholdDay = Self.dayIndex(threshold)

        switch frequency {
        case .daily:
            let periods = try Self.add(UInt64(thresholdDay - anchorDay) / interval, 1)
            let offset = try Self.multiply(periods, interval)
            return try Self.date(dayIndex: Self.offsetDay(anchorDay, by: offset))
        case .weekly:
            let anchorWeekday = Self.weekday(anchor)
            let anchorWeek = anchorDay - anchorWeekday.ordinal
            let elapsedWeeks = UInt64((thresholdDay - anchorWeek) / 7)
            var period = elapsedWeeks / interval
            for _ in 0 ..< 2 {
                let offset = try Self.multiply(Self.multiply(period, interval), 7)
                let week = try Self.offsetDay(anchorWeek, by: offset)
                for index in 0 ..< max(1, byDay.count) {
                    let weekday = byDay.isEmpty ? anchorWeekday : byDay[index]
                    let candidate = week + weekday.ordinal
                    if candidate > thresholdDay {
                        return try Self.date(dayIndex: candidate)
                    }
                }
                period = try Self.add(period, 1)
            }
        case .monthly:
            let anchorMonth = anchor.year * 12 + anchor.month - 1
            let thresholdMonth = threshold.year * 12 + threshold.month - 1
            var period = UInt64(thresholdMonth - anchorMonth) / interval
            // Gregorian month/day validity repeats after 4,800 months.
            let cycle = 4_800 / Self.gcd(interval, 4_800) + 1
            for _ in 0 ..< cycle {
                let month = try Self.add(UInt64(anchorMonth), Self.multiply(period, interval))
                guard month < 120_000 else { throw Self.dateOverflow() }
                let year = Int(month / 12)
                let monthOfYear = Int(month % 12) + 1
                for index in 0 ..< max(1, byMonthDay.count) {
                    let day = byMonthDay.isEmpty ? anchor.day : byMonthDay[index]
                    if let candidate = Self.validDayIndex(year: year, month: monthOfYear, day: day),
                       candidate > thresholdDay {
                        return try Self.date(dayIndex: candidate)
                    }
                }
                period = try Self.add(period, 1)
            }
        case .yearly:
            var period = UInt64(threshold.year - anchor.year) / interval
            let cycle = 400 / Self.gcd(interval, 400) + 1
            for _ in 0 ..< cycle {
                let year = try Self.add(UInt64(anchor.year), Self.multiply(period, interval))
                guard year <= 9_999 else { throw Self.dateOverflow() }
                for monthIndex in 0 ..< max(1, byMonth.count) {
                    let month = byMonth.isEmpty ? anchor.month : byMonth[monthIndex]
                    for dayIndex in 0 ..< max(1, byMonthDay.count) {
                        let day = byMonthDay.isEmpty ? anchor.day : byMonthDay[dayIndex]
                        if let candidate = Self.validDayIndex(year: Int(year), month: month, day: day),
                           candidate > thresholdDay {
                            return try Self.date(dayIndex: candidate)
                        }
                    }
                }
                period = try Self.add(period, 1)
            }
        }
        throw Self.invalid("Recurrence selections never produce a valid calendar date")
    }

    public static func validatePresence(
        recurrence: String?,
        recurrenceFrom: RecurrenceFrom?,
        dueDate: CivilDate?,
        lastCompletedDate: CivilDate?
    ) throws -> RecurrenceRule? {
        guard let recurrence else {
            guard recurrenceFrom == nil else {
                throw OTodoError.validation(
                    field: "recurrence_from",
                    message: "recurrence_from is invalid without recurrence"
                )
            }
            guard lastCompletedDate == nil else {
                throw OTodoError.validation(
                    field: "last_completed_date",
                    message: "last_completed_date is invalid without recurrence"
                )
            }
            return nil
        }

        let rule = try RecurrenceRule(parsing: recurrence)
        guard recurrenceFrom != nil else {
            throw OTodoError.validation(
                field: "recurrence_from",
                message: "A recurring task must have recurrence_from"
            )
        }
        guard let dueDate else {
            throw OTodoError.validation(field: "due_date", message: "A recurring task must have due_date")
        }
        guard rule.matches(dueDate) else {
            throw OTodoError.validation(
                field: "due_date",
                message: "due_date does not match the recurrence selections"
            )
        }
        return rule
    }

    private static func parseUniqueList<T: Hashable>(
        _ value: String,
        clause: String,
        parser: (String) throws -> T
    ) throws -> [T] {
        var result: [T] = []
        var seen: Set<T> = []
        for substring in value.split(separator: ",", omittingEmptySubsequences: false) {
            guard !substring.isEmpty else {
                throw invalid("\(clause) contains an empty item")
            }
            let item = String(substring)
            let parsed = try parser(item)
            guard seen.insert(parsed).inserted else {
                throw invalid("\(clause) contains duplicate value \"\(item)\"")
            }
            result.append(parsed)
        }
        return result
    }

    private static func parseNumberList(
        _ value: String,
        range: ClosedRange<Int>,
        clause: String
    ) throws -> [Int] {
        let values: [Int] = try parseUniqueList(value, clause: clause) { item in
            if item.hasPrefix("-") {
                throw invalid("\(clause) does not support negative values in v1")
            }
            guard item.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                  let number = Int(item), range.contains(number)
            else {
                throw invalid(
                    "\(clause) values must be integers from \(range.lowerBound) through \(range.upperBound)"
                )
            }
            return number
        }
        return values.sorted()
    }

    private static func dateComponents(_ date: CivilDate) -> (year: Int, month: Int, day: Int) {
        let bytes = Array(date.rawValue.utf8)
        func number(_ range: Range<Int>) -> Int {
            range.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) }
        }
        return (number(0 ..< 4), number(5 ..< 7), number(8 ..< 10))
    }

    private static func weekday(
        _ components: (year: Int, month: Int, day: Int)
    ) -> RecurrenceWeekday {
        let daysSinceUnixEpoch = dayIndex(components)
        let mondayOrdinal = ((daysSinceUnixEpoch + 3) % 7 + 7) % 7
        return RecurrenceWeekday.allCases[mondayOrdinal]
    }

    /// Proleptic Gregorian days relative to 1970-01-01, including year zero.
    private static func dayIndex(_ components: (year: Int, month: Int, day: Int)) -> Int {
        var adjustedYear = components.year
        if components.month <= 2 { adjustedYear -= 1 }
        let era = adjustedYear >= 0 ? adjustedYear / 400 : (adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = components.month + (components.month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + components.day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func validDayIndex(year: Int, month: Int, day: Int) -> Int? {
        let daysInMonth: Int
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: daysInMonth = 31
        case 4, 6, 9, 11: daysInMonth = 30
        case 2:
            let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
            daysInMonth = leap ? 29 : 28
        default: return nil
        }
        guard (1 ... daysInMonth).contains(day) else { return nil }
        return dayIndex((year, month, day))
    }

    private static func offsetDay(_ day: Int, by offset: UInt64) throws -> Int {
        let maximum = dayIndex((9_999, 12, 31))
        guard offset <= UInt64(maximum - day) else { throw dateOverflow() }
        return day + Int(offset)
    }

    private static func date(dayIndex day: Int) throws -> CivilDate {
        guard day >= dayIndex((0, 1, 1)), day <= dayIndex((9_999, 12, 31)) else {
            throw dateOverflow()
        }
        let shifted = day + 719_468
        let era = shifted >= 0 ? shifted / 146_097 : (shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        var year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let adjustedMonth = (5 * dayOfYear + 2) / 153
        let dayOfMonth = dayOfYear - (153 * adjustedMonth + 2) / 5 + 1
        let month = adjustedMonth + (adjustedMonth < 10 ? 3 : -9)
        if month <= 2 { year += 1 }
        return try CivilDate(rawValue: String(format: "%04d-%02d-%02d", year, month, dayOfMonth))
    }

    private static func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw dateOverflow() }
        return value
    }

    private static func multiply(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw dateOverflow() }
        return value
    }

    private static func gcd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var left = lhs
        var right = rhs
        while right != 0 {
            (left, right) = (right, left % right)
        }
        return left
    }

    private static func dateOverflow() -> OTodoError {
        invalid("Recurrence has no next date in the supported calendar range")
    }

    private static func invalid(_ message: String) -> OTodoError {
        .validation(field: "recurrence", message: message)
    }
}
