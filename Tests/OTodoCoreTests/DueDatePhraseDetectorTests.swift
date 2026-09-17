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

        XCTAssertEqual(detection.phrases, ["tomorrow"])
        XCTAssertEqual(detection.dueDate.rawValue, "2026-09-05")
        XCTAssertEqual(detection.nameWithoutPhrase, "📌 Call mum")
        XCTAssertEqual(
            detection.utf16Ranges.map { (input as NSString).substring(with: $0) },
            ["tomorrow"]
        )
    }

    func testTodayAndTodUseTheLocalDayAndWholeWords() throws {
        var localCalendar = calendar
        localCalendar.timeZone = TimeZone(secondsFromGMT: -8 * 60 * 60)!
        let nearMidnight = calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 4, hour: 2)
        )!
        for phrase in ["ToDaY", "TOD"] {
            let input = "📌 Call \(phrase) mum"
            let detection = try XCTUnwrap(DueDatePhraseDetector.detect(
                in: input, from: nearMidnight, calendar: localCalendar
            ))
            XCTAssertEqual(detection.dueDate.rawValue, "2026-09-03")
            XCTAssertEqual(detection.nameWithoutPhrase, "📌 Call mum")
            XCTAssertEqual(detection.utf16Ranges.map { (input as NSString).substring(with: $0) }, [phrase])
        }
        for input in ["Todd calls", "todayish", "tod2", "antoday", "étodé"] {
            XCTAssertNil(try DueDatePhraseDetector.detect(
                in: input, from: nearMidnight, calendar: localCalendar
            ), input)
        }
    }

    func testDetectsEveryWeekdayAsItsNextOccurrence() throws {
        let cases = [
            (["Sunday", "Sun"], "2026-09-06"),
            (["Monday", "Mon"], "2026-09-07"),
            (["Tuesday", "Tue", "Tues"], "2026-09-08"),
            (["Wednesday", "Wed"], "2026-09-09"),
            (["Thursday", "Thu", "Thur", "Thurs"], "2026-09-10"),
            (["Friday", "Fri"], "2026-09-11"),
            (["Saturday", "Sat"], "2026-09-05"),
        ]

        for (weekdays, expectedDate) in cases {
            for weekday in weekdays {
                let input = "Finish report \(weekday.uppercased())"
                let detection = try XCTUnwrap(
                    DueDatePhraseDetector.detect(
                        in: input,
                        from: referenceDate,
                        calendar: calendar
                    ),
                    weekday
                )
                XCTAssertEqual(detection.dueDate.rawValue, expectedDate, weekday)
                XCTAssertEqual(detection.nameWithoutPhrase, "Finish report", weekday)
            }
        }
    }

    func testAbbreviationInSentenceKeepsAnExactHighlightAndCleanName() throws {
        let input = "📌 Call mum, Wed., after lunch"
        let detection = try XCTUnwrap(
            DueDatePhraseDetector.detect(
                in: input,
                from: referenceDate,
                calendar: calendar
            )
        )

        XCTAssertEqual(detection.phrases, ["Wed"])
        XCTAssertEqual(detection.dueDate.rawValue, "2026-09-09")
        XCTAssertEqual(detection.nameWithoutPhrase, "📌 Call mum after lunch")
        XCTAssertEqual(detection.utf16Ranges.map { (input as NSString).substring(with: $0) }, ["Wed"])
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

    func testDetectsCalendarDatesWithOptionalOrdinalsAndYears() throws {
        let cases = [
            ("File taxes Oct 1", "2026-10-01", "File taxes", "Oct 1"),
            ("Plan travel May 5", "2027-05-05", "Plan travel", "May 5"),
            (
                "Renew passport June 12th 2027", "2027-06-12",
                "Renew passport", "June 12th 2027"
            ),
            (
                "Celebrate December 31st, 2026!", "2026-12-31",
                "Celebrate", "December 31st, 2026"
            ),
            ("Schedule leap review Feb 29", "2028-02-29", "Schedule leap review", "Feb 29"),
        ]

        for (input, dueDate, strippedText, phrase) in cases {
            let detection = try XCTUnwrap(
                DueDatePhraseDetector.detect(
                    in: input,
                    from: referenceDate,
                    calendar: calendar
                ),
                input
            )
            XCTAssertEqual(detection.dueDate.rawValue, dueDate, input)
            XCTAssertEqual(detection.nameWithoutPhrase, strippedText, input)
            XCTAssertEqual(detection.phrases, [phrase], input)
            XCTAssertEqual(
                detection.utf16Ranges.map { (input as NSString).substring(with: $0) },
                [phrase],
                input
            )
        }
    }

    func testLastCalendarDateWinsAndInvalidDatesRemainText() throws {
        let input = "Compare May 5 with June 12th 2027"
        let detection = try XCTUnwrap(
            DueDatePhraseDetector.detect(
                in: input,
                from: referenceDate,
                calendar: calendar
            )
        )
        XCTAssertEqual(detection.dueDate.rawValue, "2027-06-12")
        XCTAssertEqual(detection.nameWithoutPhrase, "Compare May 5 with")
        XCTAssertEqual(detection.phrases, ["June 12th 2027"])

        for invalid in [
            "Discuss February 30",
            "Review June 12nd 2027",
            "Summarize May results",
            "Revisit Oct 0",
        ] {
            XCTAssertNil(
                try DueDatePhraseDetector.detect(
                    in: invalid,
                    from: referenceDate,
                    calendar: calendar
                ),
                invalid
            )
        }
    }

    func testRemovingCalendarDateFromNotesPreservesMarkdownLayout() throws {
        let notes = """
        Agenda:
        - June 12th 2027 Venue
        - Send invites
        """
        let detection = try XCTUnwrap(
            DueDatePhraseDetector.detect(
                in: notes,
                from: referenceDate,
                calendar: calendar
            )
        )

        XCTAssertEqual(
            detection.textWithoutPhrasePreservingLayout,
            """
            Agenda:
            - Venue
            - Send invites
            """
        )
    }

    func testRejectsUnsupportedOrEmbeddedPhrases() throws {
        for input in [
            "Visit Tomorrowland",
            "Plan wedding",
            "Check Mon2 schedule",
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
