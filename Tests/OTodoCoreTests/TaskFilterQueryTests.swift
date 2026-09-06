import Foundation
import XCTest
@testable import OTodoCore

final class TaskFilterQueryTests: XCTestCase, @unchecked Sendable {
    func testBooleanPrecedenceGroupingAndOperatorSpellings() throws {
        let tasks = try [
            task(tags: ["a", "blocked"]),
            task(tags: ["b"]),
            task(tags: ["b", "blocked"]),
            task(tags: []),
        ]
        let query = try TaskFilterQuery("tag:a oR tag:b aNd nOt tag:blocked")
        let symbolic = try TaskFilterQuery("tag:a|tag:b&!tag:blocked")
        let grouped = try TaskFilterQuery("(tag:a OR tag:b) AND NOT tag:blocked")

        XCTAssertEqual(try tasks.map { try matches(query, $0) }, [true, true, false, false])
        XCTAssertEqual(try tasks.map { try matches(symbolic, $0) }, [true, true, false, false])
        XCTAssertEqual(try tasks.map { try matches(grouped, $0) }, [false, true, false, false])
        XCTAssertTrue(try matches(TaskFilterQuery("NOT NOT tag:a"), tasks[0]))
        XCTAssertFalse(try matches(TaskFilterQuery("NOT (tag:a OR tag:b)"), tasks[0]))
    }

    func testTagsAndProjectsAreExactCaseSensitiveLiterals() throws {
        let task = try task(projects: ["work-app"], tags: ["Urgent", "a.b", "AND", "résumé"])
        XCTAssertTrue(try matches(TaskFilterQuery("tag:Urgent AND project:work-app"), task))
        XCTAssertTrue(try matches(TaskFilterQuery("tag:a.b AND tag:AND AND tag:résumé"), task))
        XCTAssertFalse(try matches(TaskFilterQuery("tag:urgent OR project:WORK-APP"), task))
        XCTAssertFalse(try matches(TaskFilterQuery("tag:Ur OR project:work"), task))
        XCTAssertFalse(try matches(TaskFilterQuery("tag:/Urgent/ OR project:work.*"), task))
    }

    func testQuotedLiteralsEscapeQuotesBackslashesAndOperatorCharacters() throws {
        let task = try task(projects: ["work-app"], tags: [#"say"hi"#, #"path\name"#, "a|b", "(x)"])
        let query = try TaskFilterQuery(#"tag:"say\"hi" AND tag:"path\\name" AND tag:"a|b" AND tag:"(x)" AND project:"work-app""#)
        XCTAssertTrue(try matches(query, task))
        XCTAssertFalse(try matches(TaskFilterQuery(#"tag:"a" OR tag:"path\\other""#), task))
    }

    func testRegexUsesUnicodeUTF16RangesAndPreservesDelimiterAndICUEscapes() throws {
        let task = try task(name: "日本 Café / v2", body: "folder\\file\nSECOND line\nlast")
        XCTAssertTrue(try matches(TaskFilterQuery(#"name:/日本\s+café \/ v\d$/i"#), task))
        XCTAssertFalse(try matches(TaskFilterQuery(#"name:/café/"#), task))
        XCTAssertTrue(try matches(TaskFilterQuery(#"description:/^second\s+line$/im"#), task))
        XCTAssertFalse(try matches(TaskFilterQuery(#"description:/^SECOND line$/"#), task))
        XCTAssertTrue(try matches(TaskFilterQuery(#"description:/folder\\file.*last/s"#), task))
        XCTAssertFalse(try matches(TaskFilterQuery(#"description:/folder\\file.*last/"#), task))
        XCTAssertFalse(try matches(TaskFilterQuery(#"name:/SECOND/ OR description:/Café/"#), task))
    }

    func testBuiltinsRespectCustomTerminalStatesAndCivilDateBoundary() throws {
        let tasks = try [
            task(state: "doing", dueDate: "2026-09-04"),
            task(state: "doing", dueDate: "2026-09-05"),
            task(state: "doing", dueDate: "2026-09-06"),
            task(state: "doing"),
            task(state: "archived", dueDate: "2026-09-04"),
            task(state: "cancelled", dueDate: "2026-09-05"),
            task(state: "done", dueDate: "2026-09-05"),
        ]
        let terminalStates: Set<String> = ["archived", "cancelled"]
        for (query, expected) in [
            (TaskFilterQuery.all, [true, true, true, true, true, true, true]),
            (TaskFilterQuery.active, [true, true, true, true, false, false, true]),
            (TaskFilterQuery.today, [true, true, false, false, false, false, true]),
        ] {
            XCTAssertEqual(
                try tasks.map { try query.matches($0, terminalStateIDs: terminalStates, dates: Self.dates) },
                expected
            )
        }
        XCTAssertTrue(try TaskFilterQuery("today").matches(tasks[2], terminalStateIDs: terminalStates, dates: Self.makeDates(day: 6)))
        XCTAssertFalse(try TaskFilterQuery("active").matches(tasks[0], terminalStateIDs: ["doing"], dates: Self.dates))
        XCTAssertTrue(try TaskFilterQuery("all").matches(tasks[4], terminalStateIDs: terminalStates, dates: Self.dates))
    }

    func testInboxIncludesOnlyActiveProjectlessTasksRegardlessOfDueDate() throws {
        let tasks = try [
            task(),
            task(dueDate: "2026-09-04"),
            task(dueDate: "2026-09-05"),
            task(dueDate: "2026-09-06"),
            task(state: "archived"),
            task(state: "cancelled", dueDate: "2026-09-06"),
            task(projects: ["work"]),
            task(projects: ["work", "home"], dueDate: "2026-09-05"),
            task(state: "done"),
        ]
        let terminalStates: Set<String> = ["archived", "cancelled"]
        for query in [TaskFilterQuery.inbox, try TaskFilterQuery("inbox")] {
            XCTAssertEqual(
                try tasks.map { try query.matches($0, terminalStateIDs: terminalStates, dates: Self.dates) },
                [true, true, true, true, false, false, false, false, true]
            )
        }
        XCTAssertFalse(try TaskFilterQuery.inbox.matches(
            tasks[0], terminalStateIDs: ["doing"], dates: Self.dates
        ))
    }

    func testDatePredicatesUseInclusiveBoundsAndExcludeTerminalTasks() throws {
        let tasks = try [
            task(dueDate: "2026-09-04"),
            task(dueDate: "2026-09-05"),
            task(dueDate: "2026-09-06"),
            task(dueDate: "2026-09-07"),
            task(dueDate: "2026-09-12"),
            task(dueDate: "2026-09-13"),
            task(),
        ]
        let cases: [(String, TaskFilterQuery?, [Bool])] = [
            ("overdue", .overdue, [true, false, false, false, false, false, false]),
            ("tomorrow", .tomorrow, [false, false, true, false, false, false, false]),
            ("next-seven-days", .nextSevenDays, [false, false, true, true, true, false, false]),
            ("undated", .undated, [false, false, false, false, false, false, true]),
            ("due:2026-09-05", nil, [false, true, false, false, false, false, false]),
            ("due:2026-09-06..2026-09-12", nil, [false, false, true, true, true, false, false]),
            ("due:2026-09-05..2026-09-05", nil, [false, true, false, false, false, false, false]),
        ]
        for (source, builtin, expected) in cases {
            var queries = [try TaskFilterQuery(source)]
            if let builtin { queries.append(builtin) }
            for query in queries {
                XCTAssertEqual(try tasks.map { try matches(query, $0) }, expected, source)
                XCTAssertEqual(
                    try tasks.map { try query.matches($0, terminalStateIDs: ["doing"], dates: Self.dates) },
                    Array(repeating: false, count: tasks.count),
                    source
                )
            }
        }
        XCTAssertTrue(try matches(TaskFilterQuery("due:2028-02-29"), task(dueDate: "2028-02-29")))
    }

    func testDatePredicatesComposeWithBooleanProjectTagAndRegexFilters() throws {
        let tasks = try [
            task(name: "Ship 日本", projects: ["work"], tags: ["focus"], dueDate: "2026-09-04"),
            task(name: "Ship 日本", projects: ["work"], tags: ["focus"], dueDate: "2026-09-06"),
            task(name: "Ship 日本", projects: ["home"], tags: ["focus"], dueDate: "2026-09-06"),
            task(name: "Ship 日本", projects: ["work"], tags: ["focus", "blocked"], dueDate: "2026-09-07"),
            task(name: "Plan", projects: ["work"], tags: ["focus"]),
            task(name: "Ship 日本", state: "archived", projects: ["work"], tags: ["focus"], dueDate: "2026-09-06"),
        ]
        let query = try TaskFilterQuery(
            #"(overdue OR next-seven-days) AND project:"work" AND tag:focus AND NOT tag:blocked AND name:/^ship\s+日本$/i"#
        )
        XCTAssertEqual(try tasks.map { try matches(query, $0) }, [true, true, false, false, false, false])
        let range = try TaskFilterQuery(#"due:"2026-09-06..2026-09-07" & !tomorrow | undated"#)
        XCTAssertEqual(try tasks.map { try matches(range, $0) }, [false, false, false, true, true, false])
        let precedence = try TaskFilterQuery("overdue OR tomorrow AND project:work")
        XCTAssertEqual(try tasks.map { try matches(precedence, $0) }, [true, true, false, false, false, false])
        XCTAssertTrue(try matches(TaskFilterQuery("NOT tomorrow"), tasks[5]))
    }

    func testRejectsInvalidCivilDateLiteralsAndReversedOrOpenRanges() {
        for source in [
            "due:", "due:2026-02-29", "due:2026-04-31", "due:2026-00-10", "due:2026-09-00",
            "due:2026-9-05", "due:２０２６-09-05", "due:2026-09-05T12:00",
            "due:2026-09-06..2026-09-05", "due:2026-09-05..", "due:..2026-09-05",
            "due:2026-09-05..2026-09-06..2026-09-07", "due:2026-09-05...2026-09-06",
            #"due:"2026-09-05"suffix"#, #"due:"2026-09-05..2026-02-29""#,
        ] {
            assertInvalid(source)
        }
    }

    func testRejectsMalformedExpressionsWithFilterValidationErrors() {
        for source in [
            "", " \n\t", "all active", "all(tag:x)", "tag:x NOT tag:y",
            "AND all", "all OR", "NOT", "all && active", "all || active",
            "()", "(all", "all)", "(all OR)", "((all)",
            "unknown", "state:done", "body:/text/", "tag:", "project:",
            #"tag:"""#, #"tag:"unfinished"#, #"tag:"x"suffix"#, #"tag:"bad\q""#,
            #"tag:unquoted\escape"#, "name:text", "description:", "name:/unterminated",
            #"name:/trailing\"#, "name:/[/", "name:/x/z", "name:/x/I", "name:/x/imsq",
            "name:/x/name:/y/",
        ] {
            assertInvalid(source)
        }
    }

    func testBoundsNestingAndSourceSizeWithoutRejectingFlatExpressions() throws {
        let task = try task()
        let nested = String(repeating: "(", count: 32) + "all" + String(repeating: ")", count: 32)
        XCTAssertTrue(try matches(TaskFilterQuery(nested), task))
        let flat = Array(repeating: "active", count: 1_000).joined(separator: " OR ")
        XCTAssertTrue(try matches(TaskFilterQuery(flat), task))
        assertInvalid(String(repeating: "(", count: 100) + "all" + String(repeating: ")", count: 100))
        assertInvalid(String(repeating: "NOT ", count: 100) + "all")
        assertInvalid("tag:" + String(repeating: "é", count: 9_000))
    }

    func testAlreadyCancelledEvaluationThrowsInsteadOfPublishingAnyResult() async throws {
        let task = try task()
        let queries = try [TaskFilterQuery.all, .active, .today, TaskFilterQuery("NOT all"), TaskFilterQuery("name:/x/")]
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            for query in queries {
                do {
                    _ = try query.matches(task, terminalStateIDs: [], dates: Self.dates)
                    XCTFail("Cancelled query returned a result")
                } catch is CancellationError {
                    // Cancellation must not be converted into a false match or a validation error.
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
            }
        }
        await worker.value
    }

    func testCancellationInterruptsRegexBacktracking() async throws {
        let query = try TaskFilterQuery("name:/^(a+)+$/")
        let task = try task(name: String(repeating: "a", count: 30) + "!")
        let started = expectation(description: "Regex worker started")
        let worker = Task.detached {
            started.fulfill()
            return try query.matches(task, terminalStateIDs: [], dates: Self.dates)
        }
        defer { worker.cancel() }
        await fulfillment(of: [started], timeout: 2)
        try await Task.sleep(for: .milliseconds(20))
        let cancelledAt = ContinuousClock.now
        worker.cancel()
        do {
            _ = try await worker.value
            XCTFail("Cancelled regex returned a result")
        } catch is CancellationError {
            XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(2))
        }
    }

    func testBooleanEvaluationShortCircuitsBeforeExpensiveRegex() async throws {
        let task = try task(name: String(repeating: "a", count: 30) + "!", state: "archived")
        let either = try TaskFilterQuery("all OR name:/^(a+)+$/")
        let both = try TaskFilterQuery("active AND name:/^(a+)+$/")
        let worker = Task.detached {
            let first = try either.matches(task, terminalStateIDs: ["archived"], dates: Self.dates)
            let second = try both.matches(task, terminalStateIDs: ["archived"], dates: Self.dates)
            return [first, second]
        }
        let cancellation = Task.detached {
            try await Task.sleep(for: .seconds(2))
            worker.cancel()
        }
        defer { cancellation.cancel() }
        let results = try await worker.value
        XCTAssertEqual(results, [true, false])
    }

    private func assertInvalid(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TaskFilterQuery(source), source, file: file, line: line) { error in
            guard case let OTodoError.validation(field, _) = error else {
                return XCTFail("Expected filter validation, received \(error)", file: file, line: line)
            }
            XCTAssertEqual(field, "filterQuery", file: file, line: line)
        }
    }

    private func matches(_ query: TaskFilterQuery, _ task: TodoTask) throws -> Bool {
        try query.matches(task, terminalStateIDs: ["archived"], dates: Self.dates)
    }

    private static let dates = makeDates()

    private static func makeDates(day: Int = 5) -> TaskDateContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return TaskDateContext(
            referenceDate: calendar.date(from: DateComponents(year: 2026, month: 9, day: day))!,
            calendar: calendar
        )
    }

    private func task(
        name: String = "Task",
        state: String = "doing",
        projects: [String] = [],
        tags: [String] = [],
        dueDate: String? = nil,
        body: String = ""
    ) throws -> TodoTask {
        let rawID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        return try TodoTask(
            id: TaskID(rawValue: rawID),
            relativePath: "tasks/\(rawID).md",
            name: name,
            state: state,
            projectSlugs: projects,
            tags: tags,
            dueDate: try dueDate.map(CivilDate.init(rawValue:)),
            recurrence: nil,
            recurrenceFrom: nil,
            lastCompletedDate: nil,
            body: body,
            extraProperties: []
        )
    }
}
