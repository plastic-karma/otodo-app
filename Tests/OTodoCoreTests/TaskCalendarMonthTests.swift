import XCTest
@testable import OTodoCore

final class TaskCalendarMonthTests: XCTestCase {
    func testLeapDaysFollowGregorianCenturyRulesIncludingYearZero() throws {
        for (year, lastDay) in [("0000", "29"), ("1900", "28"), ("2000", "29"), ("2100", "28")] {
            let month = TaskCalendarMonth(containing: try date("\(year)-02-12"))
            XCTAssertEqual(month.days.last?.rawValue, "\(year)-02-\(lastDay)")
            XCTAssertEqual(month.days.count, Int(lastDay))
            XCTAssertEqual(month.nextMonth?.rawValue, "\(year)-03-01")
        }
    }

    func testWeekStartRotatesHeadersAndLeadingBlanksTogether() throws {
        let september = try date("2026-09-18") // September 1 is Tuesday.
        let sunday = TaskCalendarMonth(containing: september, firstWeekday: 1)
        let monday = TaskCalendarMonth(containing: september, firstWeekday: 2)
        let saturday = TaskCalendarMonth(containing: september, firstWeekday: 7)
        XCTAssertEqual(sunday.weekdays, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(sunday.leadingBlankCount, 2)
        XCTAssertEqual(monday.weekdays, [2, 3, 4, 5, 6, 7, 1])
        XCTAssertEqual(monday.leadingBlankCount, 1)
        XCTAssertEqual(saturday.weekdays, [7, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(saturday.leadingBlankCount, 3)
        XCTAssertEqual(sunday.days, monday.days)
        XCTAssertEqual(monday.days, saturday.days)

        let aligned = TaskCalendarMonth(containing: try date("2026-02-01"), firstWeekday: 1)
        XCTAssertEqual(aligned.leadingBlankCount, 0)
    }

    func testNavigationUsesFirstDayAcrossShortMonthsAndYears() throws {
        let march = TaskCalendarMonth(containing: try date("2024-03-31"))
        XCTAssertEqual(march.firstDay.rawValue, "2024-03-01")
        XCTAssertEqual(march.previousMonth?.rawValue, "2024-02-01")
        XCTAssertEqual(march.nextMonth?.rawValue, "2024-04-01")

        let december = TaskCalendarMonth(containing: try date("2026-12-31"))
        XCTAssertEqual(december.nextMonth?.rawValue, "2027-01-01")
        let january = TaskCalendarMonth(containing: try XCTUnwrap(december.nextMonth))
        XCTAssertEqual(january.previousMonth, december.firstDay)
    }

    func testNavigationStopsAtCivilDateStorageBounds() throws {
        let earliest = TaskCalendarMonth(containing: try date("0000-01-01"), firstWeekday: 1)
        XCTAssertNil(earliest.previousMonth)
        XCTAssertEqual(earliest.nextMonth?.rawValue, "0000-02-01")
        XCTAssertEqual(earliest.leadingBlankCount, 6) // Proleptic Gregorian Saturday.
        let latest = TaskCalendarMonth(containing: try date("9999-12-31"))
        XCTAssertNil(latest.nextMonth)
        XCTAssertEqual(latest.previousMonth?.rawValue, "9999-11-01")
        XCTAssertEqual(latest.days.last?.rawValue, "9999-12-31")
    }

    func testHistoricalCutoverDoesNotRemoveStoredGregorianDays() throws {
        let october = TaskCalendarMonth(containing: try date("1582-10-10"), firstWeekday: 1)
        XCTAssertEqual(october.leadingBlankCount, 5) // Proleptic Gregorian Friday.
        XCTAssertEqual(october.days.count, 31)
        XCTAssertEqual(october.days[3].rawValue, "1582-10-04")
        XCTAssertEqual(october.days[4].rawValue, "1582-10-05")
        XCTAssertEqual(october.days[13].rawValue, "1582-10-14")
        XCTAssertEqual(october.days[14].rawValue, "1582-10-15")
        XCTAssertEqual(october.days.last?.rawValue, "1582-10-31")
    }

    private func date(_ value: String) throws -> CivilDate {
        try CivilDate(rawValue: value)
    }
}
