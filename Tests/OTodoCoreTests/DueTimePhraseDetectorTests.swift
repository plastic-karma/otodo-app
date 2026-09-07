import Foundation
import XCTest
@testable import OTodoCore

final class DueTimePhraseDetectorTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var referenceDate: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 12))!
    }

    func testClockGrammarIncludesMidnightNoonAndTwentyFourHourBoundaries() throws {
        for (phrase, time) in [
            ("00:00", "00:00"), ("23:59", "23:59"),
            ("12 am", "00:00"), ("12 PM", "12:00"),
            ("at 1:05 pm", "13:05"), ("AT 9am", "09:00"),
        ] {
            let detected = try detect("Call \(phrase)")
            XCTAssertEqual(detected.dueDate.rawValue, "2026-09-04", phrase)
            XCTAssertEqual(detected.dueTime?.rawValue, time, phrase)
            XCTAssertEqual(detected.nameWithoutPhrase, "Call", phrase)
        }
    }

    func testSeparatedDateAndClockPreserveUnicodeTitleAndExactHighlightRanges() throws {
        let input = "  📌 Café tomorrow with Zoë at 3:05 pm  "
        let detected = try detect(input)
        XCTAssertEqual(detected.dueDate.rawValue, "2026-09-05")
        XCTAssertEqual(detected.dueTime?.rawValue, "15:05")
        XCTAssertEqual(detected.nameWithoutPhrase, "📌 Café with Zoë")
        XCTAssertEqual(detected.utf16Ranges.map { (input as NSString).substring(with: $0) }, ["tomorrow", "at 3:05 pm"])
        let reverse = try detect("📌 15:05 Café tomorrow with Zoë")
        XCTAssertEqual(reverse.nameWithoutPhrase, "📌 Café with Zoë")
        XCTAssertEqual(reverse.dueDate, detected.dueDate)
        XCTAssertEqual(reverse.dueTime, detected.dueTime)
    }

    func testTimeOnlyKeepsSelectedDateWhileExplicitDateOverridesIt() throws {
        let selected = try CivilDate(rawValue: "2026-12-25")
        let clockOnly = try detect("Call at 14:30")
        XCTAssertEqual(clockOnly.resolvedDueDate(selectedDate: selected), selected)
        XCTAssertEqual(clockOnly.resolvedDueDate(selectedDate: nil).rawValue, "2026-09-04")
        let explicit = try detect("Call tomorrow at 14:30")
        XCTAssertEqual(explicit.resolvedDueDate(selectedDate: selected).rawValue, "2026-09-05")
    }

    func testLastDateAndTimeWinIndependentlyWithoutRemovingOtherTitleText() throws {
        let detected = try detect("Call today at 9 am tomorrow with team at 4 pm")
        XCTAssertEqual(detected.dueDate.rawValue, "2026-09-05")
        XCTAssertEqual(detected.dueTime?.rawValue, "16:00")
        XCTAssertEqual(detected.nameWithoutPhrase, "Call today at 9 am with team")
        let relative = try detect("Call in 2 hours tomorrow at 4 pm")
        XCTAssertEqual(relative.dueDate.rawValue, "2026-09-05")
        XCTAssertEqual(relative.dueTime?.rawValue, "16:00")
        XCTAssertEqual(relative.nameWithoutPhrase, "Call in 2 hours")
        let dateFromRelative = try detect("Call in 2 hours at 4 pm")
        XCTAssertEqual(dateFromRelative.nameWithoutPhrase, "Call")
        XCTAssertEqual(dateFromRelative.dueDate.rawValue, "2026-09-04")
        XCTAssertEqual(dateFromRelative.dueTime?.rawValue, "16:00")
    }

    func testRelativeMinutesCrossMidnightAndRoundUsingExistingExpressionRules() throws {
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 4, hour: 23, minute: 59, second: 45
        )))
        let detected = try XCTUnwrap(DueDatePhraseDetector.detect(
            in: "Check oven in 1 minute", from: reference, calendar: calendar
        ))
        XCTAssertEqual(detected.dueDate.rawValue, "2026-09-05")
        XCTAssertEqual(detected.dueTime?.rawValue, "00:01")
        XCTAssertEqual(detected.nameWithoutPhrase, "Check oven")
        XCTAssertEqual(detected.resolvedDueDate(selectedDate: try CivilDate(rawValue: "2026-12-25")), detected.dueDate)
        XCTAssertEqual(detected.utf16Ranges.count, 1, "A relative phrase contributes both components but is removed only once")
    }

    func testRelativeHoursFollowDaylightSavingWhileClockOnlyUsesLocalToday() throws {
        var local = calendar
        local.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let reference = try XCTUnwrap(local.date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 1, minute: 45
        )))
        let relative = try XCTUnwrap(DueDatePhraseDetector.detect(
            in: "Call in 1 hour", from: reference, calendar: local
        ))
        XCTAssertEqual(relative.dueDate.rawValue, "2026-03-08")
        XCTAssertEqual(relative.dueTime?.rawValue, "03:45")
        let utcEarlyMorning = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 4, hour: 2
        )))
        let clock = try XCTUnwrap(DueDatePhraseDetector.detect(
            in: "Call 09:30", from: utcEarlyMorning, calendar: local
        ))
        XCTAssertEqual(clock.dueDate.rawValue, "2026-09-03")
    }

    func testMalformedClocksNumbersIdentifiersAndURLsAreNotPartiallyMatched() throws {
        for input in [
            "Call 24:00", "Call 09:60", "Call 9:30", "Call 009:30", "Call 09:300",
            "Call 09:30:00", "Call 09:30:", "Call 09:3 pm", "Call 13:00 pm", "Call 0 am",
            "Call 12:60 am", "Call 09:30 pmish", "Call 3 p.m.", "Call -09:30", "Call 09:30.5",
            "Build v09:30", "Build 09:30beta", "Build 9am2", "Build task_09:30",
            "Open https://example.test/09:30", "Open https://example.test:14:30/path",
            "Open https://example.test?time=09:30", "Open https://example.test/today",
            "Call in 2 hours/path",
            "Read 2026-09-04", "Read 42", "Call in 0 hours", "Call in -2 hours", "Call in 1.5 hours",
        ] {
            XCTAssertNil(try DueDatePhraseDetector.detect(in: input, from: referenceDate, calendar: calendar), input)
        }
        let partiallyValid = try detect("Call tomorrow at 25:30")
        XCTAssertEqual(partiallyValid.nameWithoutPhrase, "Call at 25:30")
        XCTAssertNil(partiallyValid.dueTime)
    }

    func testRemovingPhrasesDoesNotDeleteUnmatchedPunctuationOrURLCharacters() throws {
        let detected = try detect("Read https://example.test/ at 14:30 with team!")
        XCTAssertEqual(detected.nameWithoutPhrase, "Read https://example.test/ with team!")
    }

    private func detect(_ input: String) throws -> DetectedDueDatePhrase {
        try XCTUnwrap(DueDatePhraseDetector.detect(in: input, from: referenceDate, calendar: calendar))
    }
}
