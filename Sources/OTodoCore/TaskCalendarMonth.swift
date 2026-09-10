import Foundation

/// A proleptic Gregorian month, independent of time zones and Foundation's historical cutover.
public struct TaskCalendarMonth: Sendable, Equatable {
    public let year: Int
    public let month: Int
    public let firstDay: CivilDate
    public let days: [CivilDate]
    public let leadingBlankCount: Int
    /// Foundation weekday numbers, ordered from the requested first weekday (Sunday is 1).
    public let weekdays: [Int]
    public let previousMonth: CivilDate?
    public let nextMonth: CivilDate?

    public init(containing date: CivilDate, firstWeekday: Int = Calendar.current.firstWeekday) {
        precondition((1 ... 7).contains(firstWeekday), "A weekday must be in 1...7")
        let year = Int(date.rawValue.prefix(4))!
        let month = Int(date.rawValue.dropFirst(5).prefix(2))!
        self.year = year
        self.month = month
        firstDay = Self.date(year: year, month: month, day: 1)
        days = (1 ... Self.dayCount(year: year, month: month)).map {
            Self.date(year: year, month: month, day: $0)
        }
        weekdays = (0 ..< 7).map { (firstWeekday - 1 + $0) % 7 + 1 }

        // Adding 400 preserves Gregorian weekdays and keeps year-zero arithmetic positive.
        let precedingYear = year + 399
        let precedingDays = 365 * precedingYear + precedingYear / 4
            - precedingYear / 100 + precedingYear / 400
        let daysBeforeMonth = (1 ..< month).reduce(0) {
            $0 + Self.dayCount(year: year, month: $1)
        }
        let weekday = (precedingDays + daysBeforeMonth + 1) % 7 + 1
        leadingBlankCount = (weekday - firstWeekday + 7) % 7

        if month > 1 {
            previousMonth = Self.date(year: year, month: month - 1, day: 1)
        } else if year > 0 {
            previousMonth = Self.date(year: year - 1, month: 12, day: 1)
        } else {
            previousMonth = nil
        }
        if month < 12 {
            nextMonth = Self.date(year: year, month: month + 1, day: 1)
        } else if year < 9999 {
            nextMonth = Self.date(year: year + 1, month: 1, day: 1)
        } else {
            nextMonth = nil
        }
    }

    private static func dayCount(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400)) ? 29 : 28
        case 4, 6, 9, 11:
            30
        default:
            31
        }
    }

    private static func date(year: Int, month: Int, day: Int) -> CivilDate {
        // All components originate from a validated CivilDate or bounded month arithmetic.
        try! CivilDate(rawValue: String(format: "%04d-%02d-%02d", year, month, day))
    }
}
