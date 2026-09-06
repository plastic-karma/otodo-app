import XCTest
@testable import OTodoCore

final class RecurrenceRuleTests: XCTestCase {
    func testDailyAnchorsSkipMissedOccurrencesAndRespectEarlyCompletion() throws {
        let rule = try RecurrenceRule(parsing: "FREQ=DAILY;INTERVAL=3")
        let due = try date("2026-09-01")
        let late = try date("2026-09-09")
        XCTAssertEqual(try rule.nextDue(currentDue: due, completedOn: late, mode: .schedule), try date("2026-09-10"))
        XCTAssertEqual(try rule.nextDue(currentDue: due, completedOn: late, mode: .completion), try date("2026-09-12"))
        let early = try date("2026-08-29")
        XCTAssertEqual(try rule.nextDue(currentDue: due, completedOn: early, mode: .schedule), try date("2026-09-04"))
        XCTAssertEqual(try rule.nextDue(currentDue: due, completedOn: early, mode: .completion), due)
    }

    func testWeeklySelectionRetainsMondayBasedIntervalAlignment() throws {
        let rule = try RecurrenceRule(parsing: "FREQ=WEEKLY;INTERVAL=2;BYDAY=TH,MO")
        let due = try date("2026-09-07")
        XCTAssertEqual(try rule.nextDue(currentDue: due, completedOn: due, mode: .schedule), try date("2026-09-10"))
        XCTAssertEqual(try rule.nextDue(currentDue: due, completedOn: date("2026-09-11"), mode: .schedule), try date("2026-09-21"))
        XCTAssertEqual(try rule.nextDue(currentDue: due, completedOn: date("2026-09-16"), mode: .schedule), try date("2026-09-21"))
        XCTAssertEqual(try rule.nextDue(currentDue: due, completedOn: date("2026-09-16"), mode: .completion), try date("2026-09-17"))
        let implicit = try RecurrenceRule(parsing: "FREQ=WEEKLY;INTERVAL=2")
        XCTAssertEqual(try implicit.nextDue(currentDue: due, completedOn: date("2026-09-09"), mode: .completion), try date("2026-09-23"))
    }

    func testMonthlyAndYearlySkipImpossibleDatesRatherThanClamping() throws {
        let cases: [(String, String, String)] = [
            ("FREQ=MONTHLY", "2026-01-31", "2026-03-31"),
            ("FREQ=MONTHLY;BYMONTHDAY=29", "2025-01-29", "2025-03-29"),
            ("FREQ=MONTHLY;BYMONTHDAY=29", "2024-01-29", "2024-02-29"),
            ("FREQ=MONTHLY;BYMONTHDAY=15,31", "2026-01-31", "2026-02-15"),
            ("FREQ=MONTHLY;INTERVAL=2", "2026-07-31", "2027-01-31"),
            ("FREQ=YEARLY", "2096-02-29", "2104-02-29"),
            ("FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29", "1996-02-29", "2000-02-29"),
        ]
        for (source, current, expected) in cases {
            let rule = try RecurrenceRule(parsing: source)
            let due = try date(current)
            XCTAssertEqual(try rule.nextDue(currentDue: due, completedOn: due, mode: .schedule), try date(expected), source)
        }
        let yearly = try RecurrenceRule(parsing: "FREQ=YEARLY;INTERVAL=2;BYMONTH=2,4;BYMONTHDAY=29,31")
        XCTAssertEqual(try yearly.nextDue(currentDue: date("2026-04-29"), completedOn: date("2027-08-01"), mode: .schedule), try date("2028-02-29"))
    }

    func testAbsentMonthlyAndYearlySelectionsDeriveFromCompletionAnchor() throws {
        let monthly = try RecurrenceRule(parsing: "FREQ=MONTHLY;INTERVAL=2")
        XCTAssertEqual(try monthly.nextDue(currentDue: date("2026-01-31"), completedOn: date("2026-02-10"), mode: .completion), try date("2026-04-10"))
        let yearly = try RecurrenceRule(parsing: "FREQ=YEARLY")
        XCTAssertEqual(try yearly.nextDue(currentDue: date("2024-02-29"), completedOn: date("2026-09-09"), mode: .completion), try date("2027-09-09"))
    }

    func testYearZeroAndUpperDateBoundary() throws {
        let daily = try RecurrenceRule(parsing: "FREQ=DAILY")
        XCTAssertEqual(try daily.nextDue(currentDue: date("0000-02-28"), completedOn: date("0000-02-28"), mode: .schedule), try date("0000-02-29"))
        XCTAssertEqual(try daily.nextDue(currentDue: date("9999-12-30"), completedOn: date("9999-12-30"), mode: .schedule), try date("9999-12-31"))
        let weekly = try RecurrenceRule(parsing: "FREQ=WEEKLY;BYDAY=MO,SU")
        XCTAssertEqual(try weekly.nextDue(currentDue: date("0000-01-01"), completedOn: date("0000-01-01"), mode: .completion), try date("0000-01-02"))
        for frequency in RecurrenceFrequency.allCases {
            let rule = try RecurrenceRule(frequency: frequency)
            assertRecurrenceFailure {
                try rule.nextDue(currentDue: date("9999-12-31"), completedOn: date("9999-12-31"), mode: .schedule)
            }
        }
    }

    func testHugeIntervalsAndImpossibleCalendarCyclesFailWithoutWrapping() throws {
        for frequency in RecurrenceFrequency.allCases {
            let rule = try RecurrenceRule(frequency: frequency, interval: UInt64.max)
            assertRecurrenceFailure {
                try rule.nextDue(currentDue: date("2026-09-07"), completedOn: date("2026-09-07"), mode: .schedule)
            }
        }
        // A huge interval still permits another selected date in the anchor period.
        let samePeriod = try RecurrenceRule(parsing: "FREQ=WEEKLY;INTERVAL=18446744073709551615;BYDAY=MO,TH")
        XCTAssertEqual(try samePeriod.nextDue(currentDue: date("2026-09-07"), completedOn: date("2026-09-07"), mode: .schedule), try date("2026-09-10"))
        for source in ["FREQ=MONTHLY;INTERVAL=12;BYMONTHDAY=31", "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30", "FREQ=YEARLY;INTERVAL=4;BYMONTH=2;BYMONTHDAY=29"] {
            let rule = try RecurrenceRule(parsing: source)
            assertRecurrenceFailure {
                try rule.nextDue(currentDue: date("2025-02-01"), completedOn: date("2025-02-01"), mode: .completion)
            }
        }
    }

    private func date(_ value: String) throws -> CivilDate {
        try CivilDate(rawValue: value)
    }

    private func assertRecurrenceFailure(
        file: StaticString = #filePath, line: UInt = #line,
        _ operation: () throws -> CivilDate
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let error = error as? OTodoError,
                  case .validation(field: "recurrence", message: _) = error else {
                return XCTFail("Expected recurrence validation, got \(error)", file: file, line: line)
            }
        }
    }
}
