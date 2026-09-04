import Foundation
import XCTest
@testable import OTodoCore

final class DueDatePhraseDetectorTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testDetectsTomorrowAndReturnsAnExactHighlightRange() throws {
        let input = "📌 Call mum tomorrow!"
        let detection = try XCTUnwrap(
            DueDatePhraseDetector.detect(
                in: input,
                from: referenceDate,
                calendar: calendar
            )
        )

        XCTAssertEqual(detection.phrase, "tomorrow")
        XCTAssertEqual(detection.dueDate.rawValue, "2026-09-05")
        XCTAssertEqual(detection.nameWithoutPhrase, "📌 Call mum")
        XCTAssertEqual(
            (input as NSString).substring(with: detection.utf16Range),
            "tomorrow"
        )
    }

    func testDetectsEveryWeekdayAsItsNextOccurrence() throws {
        let cases = [
            ("Sunday", "2026-09-06"),
            ("Monday", "2026-09-07"),
            ("Tuesday", "2026-09-08"),
            ("Wednesday", "2026-09-09"),
            ("Thursday", "2026-09-10"),
            ("Friday", "2026-09-11"),
            ("Saturday", "2026-09-05"),
        ]

        for (weekday, expectedDate) in cases {
            let input = "Finish report \(weekday.uppercased())"
            let detection = try XCTUnwrap(
                DueDatePhraseDetector.detect(
                    in: input,
                    from: referenceDate,
                    calendar: calendar
                )
            )
            XCTAssertEqual(detection.dueDate.rawValue, expectedDate, weekday)
            XCTAssertEqual(detection.nameWithoutPhrase, "Finish report", weekday)
        }
    }

    func testDetectsRelativeDaysWeeksAndMonths() throws {
        let cases = [
            ("Ship in 3 days", "2026-09-07", "Ship"),
            ("Review in 2 weeks", "2026-09-18", "Review"),
            ("Budget in 2 months", "2026-11-04", "Budget"),
            ("Call in 1 day", "2026-09-05", "Call"),
        ]

        for (input, expectedDate, expectedName) in cases {
            let detection = try XCTUnwrap(
                DueDatePhraseDetector.detect(
                    in: input,
                    from: referenceDate,
                    calendar: calendar
                )
            )
            XCTAssertEqual(detection.dueDate.rawValue, expectedDate, input)
            XCTAssertEqual(detection.nameWithoutPhrase, expectedName, input)
        }
    }

    func testDetectsNextWeekAndNextMonth() throws {
        let cases = [
            ("Plan launch next week", "2026-09-11", "Plan launch"),
            ("Close books next month", "2026-10-04", "Close books"),
        ]

        for (input, expectedDate, expectedName) in cases {
            let detection = try XCTUnwrap(
                DueDatePhraseDetector.detect(
                    in: input,
                    from: referenceDate,
                    calendar: calendar
                )
            )
            XCTAssertEqual(detection.dueDate.rawValue, expectedDate, input)
            XCTAssertEqual(detection.nameWithoutPhrase, expectedName, input)
        }
    }

    func testRejectsUnsupportedOrEmbeddedPhrases() throws {
        for input in [
            "Visit Tomorrowland",
            "Wait in 3 hours",
            "Wait in 0 days",
            "Someday maybe",
            "Discuss next quarter",
        ] {
            XCTAssertNil(
                try DueDatePhraseDetector.detect(
                    in: input,
                    from: referenceDate,
                    calendar: calendar
                ),
                input
            )
        }
    }

    private var referenceDate: Date {
        calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: 2026,
                month: 9,
                day: 4,
                hour: 12
            )
        )!
    }
}
