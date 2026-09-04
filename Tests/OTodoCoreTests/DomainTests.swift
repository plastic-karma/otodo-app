import Foundation
import XCTest
@testable import OTodoCore

final class DomainTests: XCTestCase {
    func testTaskIDNormalizesValidLowercaseULID() throws {
        let id = try TaskID(rawValue: "01arz3ndektsv4rrffq69g5fav")
        XCTAssertEqual(id.rawValue, "01ARZ3NDEKTSV4RRFFQ69G5FAV")
    }

    func testTaskIDRejectsOverflowAndAmbiguousCharacters() {
        XCTAssertThrowsError(try TaskID(rawValue: "81ARZ3NDEKTSV4RRFFQ69G5FAV"))
        XCTAssertThrowsError(try TaskID(rawValue: "01ARZ3NDEKTSV4RRFFQ69G5FAI"))
    }

    func testCivilDateUsesProlepticGregorianCalendarIncludingYearZero() throws {
        XCTAssertEqual(try CivilDate(rawValue: "0000-02-29").rawValue, "0000-02-29")
        XCTAssertThrowsError(try CivilDate(rawValue: "2025-02-29"))
        XCTAssertNoThrow(try CivilDate(rawValue: "2024-02-29"))
    }

    func testCivilTimeUsesMinuteGranularity() throws {
        let midnight = try CivilTime(rawValue: "00:00")
        let finalMinute = try CivilTime(rawValue: "23:59")

        XCTAssertEqual(midnight.hour, 0)
        XCTAssertEqual(midnight.minute, 0)
        XCTAssertLessThan(midnight, finalMinute)

        let encoded = try JSONEncoder().encode(finalMinute)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"23:59\"")
        XCTAssertEqual(try JSONDecoder().decode(CivilTime.self, from: encoded), finalMinute)
        XCTAssertThrowsError(
            try JSONDecoder().decode(CivilTime.self, from: Data("\"24:00\"".utf8))
        )
        XCTAssertThrowsError(try CivilTime(rawValue: "9:00"))
        XCTAssertThrowsError(try CivilTime(rawValue: "24:00"))
        XCTAssertThrowsError(try CivilTime(rawValue: "23:60"))
        XCTAssertThrowsError(try CivilTime(rawValue: "12:34:56"))
    }

    func testRepositorySelectionNormalizesStorePath() throws {
        let selection = try RepositorySelection(
            owner: "example",
            name: "vault",
            branch: "main",
            storePath: "/Todo/"
        )
        XCTAssertEqual(selection.storePath, "Todo")
    }

    func testStoreConfigurationBuildsCanonicalLinks() throws {
        let states = [try WorkflowState(id: "open", name: "Open", isTerminal: false)]
        let prefixed = try StoreConfiguration(
            schemaVersion: 1,
            tasksDirectory: "Tasks",
            projectsDirectory: "Projects",
            obsidianLinkPrefix: "Todo",
            defaultState: "open",
            states: states
        )
        XCTAssertEqual(try prefixed.projectLink(slug: "work"), "[[Todo/Projects/work]]")
        XCTAssertEqual(prefixed.todosBaseLink, "[[Todo/todos.base]]")

        let unprefixed = try StoreConfiguration(
            schemaVersion: 1,
            tasksDirectory: "Tasks",
            projectsDirectory: "Projects",
            obsidianLinkPrefix: "",
            defaultState: "open",
            states: states
        )
        XCTAssertEqual(try unprefixed.projectLink(slug: "work"), "[[Projects/work]]")
        XCTAssertEqual(unprefixed.todosBaseLink, "[[todos.base]]")
    }

    func testTaskRejectsReservedIDExtraAndBracketTag() throws {
        let id = try TaskID(rawValue: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        XCTAssertThrowsError(
            try TodoTask(
                id: id,
                relativePath: "Tasks/\(id.rawValue).md",
                name: "Invalid",
                state: "open",
                projectSlugs: [],
                tags: ["bad[tag"],
                dueDate: nil,
                recurrence: nil,
                recurrenceFrom: nil,
                lastCompletedDate: nil,
                body: "",
                extraProperties: []
            )
        )
        XCTAssertThrowsError(
            try TodoTask(
                id: id,
                relativePath: "Tasks/\(id.rawValue).md",
                name: "Invalid",
                state: "open",
                projectSlugs: [],
                tags: [],
                dueDate: nil,
                recurrence: nil,
                recurrenceFrom: nil,
                lastCompletedDate: nil,
                body: "",
                extraProperties: [YAMLProperty(name: "id", value: .string(id.rawValue))]
            )
        )
    }

    func testTaskIDRejectsUnicodeThatUppercasesToCrockfordASCII() {
        XCTAssertThrowsError(try TaskID(rawValue: "01arz3ndektsv4rrffq69g5faſ"))
    }

    func testConfigurationRejectsWikilinkSyntaxInProjectsDirectory() throws {
        let states = [try WorkflowState(id: "open", name: "Open", isTerminal: false)]
        XCTAssertThrowsError(
            try StoreConfiguration(
                schemaVersion: 1,
                tasksDirectory: "Tasks",
                projectsDirectory: "Projects|Alias",
                obsidianLinkPrefix: "Todo",
                defaultState: "open",
                states: states
            )
        )
    }

    func testWorkspaceRejectsDuplicateTaskIdentityAcrossPaths() throws {
        let id = try TaskID(rawValue: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let state = try WorkflowState(id: "open", name: "Open", isTerminal: false)
        let configuration = try StoreConfiguration(
            schemaVersion: 1,
            tasksDirectory: "Tasks",
            projectsDirectory: "Projects",
            obsidianLinkPrefix: "Todo",
            defaultState: "open",
            states: [state]
        )
        let selection = try RepositorySelection(
            owner: "example",
            name: "vault",
            branch: "main",
            storePath: "Todo"
        )
        func task(at path: String) throws -> TodoTask {
            try TodoTask(
                id: id,
                relativePath: path,
                name: "Duplicate",
                state: "open",
                projectSlugs: [],
                tags: [],
                dueDate: nil,
                recurrence: nil,
                recurrenceFrom: nil,
                lastCompletedDate: nil,
                body: "",
                extraProperties: []
            )
        }
        let first = try task(at: "Tasks/a/\(id.rawValue).md")
        let second = try task(at: "Tasks/b/\(id.rawValue).md")

        XCTAssertThrowsError(
            try WorkspaceState(
                selection: selection,
                configuration: configuration,
                tasks: [
                    TaskDocument(task: first, content: "first", blobSHA: "a"),
                    TaskDocument(task: second, content: "second", blobSHA: "b"),
                ],
                baseHeadCommitSHA: "head",
                baseRootTreeSHA: "tree",
                pendingChanges: [],
                conflicts: []
            )
        )
    }

    func testSyncReportDecodingRejectsNegativeCounts() {
        let data = Data(#"{"pulledCount":-1,"pushedCount":0,"conflicts":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SyncReport.self, from: data))
    }

    func testRelativeDueDateResolvesDocumentedExamples() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let referenceDate = try date(
            year: 2026,
            month: 9,
            day: 4,
            hour: 10,
            minute: 15,
            calendar: calendar
        )

        let examples = [
            ("in 3 days", "2026-09-07", "10:15"),
            ("in 6 hours", "2026-09-04", "16:15"),
            ("in 6 months", "2027-03-04", "10:15"),
        ]

        for (input, expectedDate, expectedTime) in examples {
            let result = try RelativeDueDateExpression(input).resolve(
                from: referenceDate,
                calendar: calendar
            )
            XCTAssertEqual(result.date.rawValue, expectedDate, input)
            XCTAssertEqual(result.time.rawValue, expectedTime, input)
        }
    }

    func testRelativeDueDateAcceptsEveryCalendarUnitAndFlexibleCasing() throws {
        let units: [(String, RelativeDueDateExpression.Unit)] = [
            ("minute", .minute),
            ("hours", .hour),
            ("day", .day),
            ("weeks", .week),
            ("month", .month),
            ("years", .year),
        ]

        for (rawUnit, expectedUnit) in units {
            let expression = try RelativeDueDateExpression(" \nIN 2 \(rawUnit)\t")
            XCTAssertEqual(expression.amount, 2)
            XCTAssertEqual(expression.unit, expectedUnit)
        }
    }

    func testRelativeDueDateRejectsMalformedOrNonpositiveInput() {
        for input in [
            "",
            "3 days",
            "after 3 days",
            "in 0 days",
            "in -1 day",
            "in 1.5 days",
            "in one day",
            "in 3 fortnights",
            "in 3 days from now",
        ] {
            XCTAssertThrowsError(try RelativeDueDateExpression(input), input)
        }
    }

    func testRelativeDueDateRoundsForwardToMinuteGranularity() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let referenceDate = try date(
            year: 2026,
            month: 9,
            day: 4,
            hour: 10,
            minute: 15,
            second: 30,
            calendar: calendar
        )

        let result = try RelativeDueDateExpression("in 6 hours").resolve(
            from: referenceDate,
            calendar: calendar
        )

        XCTAssertEqual(result.date.rawValue, "2026-09-04")
        XCTAssertEqual(result.time.rawValue, "16:16")
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int = 0,
        calendar: Calendar
    ) throws -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return try XCTUnwrap(calendar.date(from: components))
    }

}
