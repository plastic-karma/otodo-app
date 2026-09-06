import Foundation
import XCTest
@testable import OTodoCore

final class TaskFilterCompletionTests: XCTestCase {
    func testMiddleOfValuePreservesUnicodeRegexGroupingAndFollowingTerms() throws {
        let (query, selection) = caret(#"name:/🧭/ & (project:wo¦rong | tag:later)"#)
        let suggestion = try XCTUnwrap(TaskFilterCompletion.suggestions(
            in: query, selection: selection, projectChoices: ["work-app"], tagChoices: []
        ).first)
        let result = try XCTUnwrap(suggestion.applying(to: query))
        XCTAssertEqual(result.query, #"name:/🧭/ & (project:work-app | tag:later)"#)
        XCTAssertEqual(result.selection, NSRange(location: (#"name:/🧭/ & (project:work-app"#).utf16.count, length: 0))
        XCTAssertTrue(try matches(result.query, name: "🧭 Task", projects: ["work-app"]))
        XCTAssertFalse(try matches(result.query, name: "Other", projects: ["work-app"]))
        XCTAssertFalse(try matches(result.query, name: "🧭 Task", projects: ["wrong"]))
    }

    func testQuotedValueReplacementEscapesQuotesBackslashesAndOperators() throws {
        let value = #"say"hi\name|(x)"#
        let (query, selection) = caret(#"active & tag:"sa¦junk""#)
        let suggestion = try XCTUnwrap(TaskFilterCompletion.suggestions(
            in: query, selection: selection, projectChoices: [], tagChoices: [value]
        ).first)
        let result = try XCTUnwrap(suggestion.applying(to: query))
        XCTAssertTrue(try matches(result.query, tags: [value]))
        XCTAssertFalse(try matches(result.query, tags: ["sajunk"]))
        XCTAssertEqual(result.selection.location, result.query.utf16.count)

        let (escapedQuery, escapedSelection) = caret(#"tag:"say\"h¦unfinished""#)
        let escaped = try XCTUnwrap(TaskFilterCompletion.suggestions(
            in: escapedQuery, selection: escapedSelection, projectChoices: [], tagChoices: [value]
        ).first?.applying(to: escapedQuery))
        XCTAssertTrue(try matches(escaped.query, tags: [value]))
    }

    func testSelectionWithinUnicodeValueReplacesWholeValueNotNeighboringPredicate() throws {
        let query = "tag:réold & project:work"
        let selection = (query as NSString).range(of: "old")
        let result = try XCTUnwrap(TaskFilterCompletion.suggestions(
            in: query, selection: selection, projectChoices: [], tagChoices: ["résumé🔖"]
        ).first?.applying(to: query))
        XCTAssertEqual(result.query, "tag:résumé🔖 & project:work")
        XCTAssertEqual(result.selection, NSRange(location: "tag:résumé🔖".utf16.count, length: 0))
        XCTAssertTrue(try matches(result.query, projects: ["work"], tags: ["résumé🔖"]))
        XCTAssertFalse(try matches(result.query, tags: ["résumé🔖"]))

        let acrossTerms = NSRange(location: 4, length: query.utf16.count - 4)
        XCTAssertTrue(TaskFilterCompletion.suggestions(
            in: query, selection: acrossTerms, projectChoices: ["work"], tagChoices: ["résumé🔖"]
        ).isEmpty)
    }

    func testEmptyValuesAndPartialFieldNamesWorkBesideSymbolicOperators() throws {
        for source in ["!(pro¦)&tag:focus", "!(project:¦)&tag:focus", "!(project:\"¦\")&tag:focus"] {
            let (query, selection) = caret(source)
            let suggestions = TaskFilterCompletion.suggestions(
                in: query, selection: selection, projectChoices: ["", "work", "work"], tagChoices: ["focus"]
            )
            XCTAssertEqual(suggestions.count, 1)
            let result = try XCTUnwrap(suggestions.first?.applying(to: query))
            XCTAssertTrue(try matches(result.query, projects: ["home"], tags: ["focus"]))
            XCTAssertFalse(try matches(result.query, projects: ["work"], tags: ["focus"]))
            XCTAssertFalse(try matches(result.query, projects: ["home"]))
        }
    }

    func testRegexAndUnrelatedLiteralsDoNotOfferProjectOrTagCompletions() {
        let sources = [
            #"name:/tag:fo¦/"#,
            #"description:/escaped\/ project:wo¦/i"#,
            #"name:/unclosed (tag:fo¦"#,
            #"name:/tag:focus/¦i"#,
            #"due:"project:wo¦""#,
            #"unknown:"tag:fo¦""#,
            #"tag:"unrelated project:wo¦""#,
        ]
        for source in sources {
            let (query, selection) = caret(source)
            XCTAssertTrue(TaskFilterCompletion.suggestions(
                in: query, selection: selection, projectChoices: ["work"], tagChoices: ["focus"]
            ).isEmpty, source)
        }
    }

    func testRegexEscapesDoNotHideLaterCompletionAndUnclosedQuoteCanBeCompleted() throws {
        let (query, selection) = caret(#"name:/folder\/🧭/ & tag:"fo¦"#)
        let result = try XCTUnwrap(TaskFilterCompletion.suggestions(
            in: query, selection: selection, projectChoices: [], tagChoices: ["focus|later"]
        ).first?.applying(to: query))
        XCTAssertTrue(try matches(result.query, name: "folder/🧭", tags: ["focus|later"]))
        XCTAssertFalse(try matches(result.query, name: "elsewhere", tags: ["focus|later"]))
    }

    private func caret(_ markedQuery: String) -> (String, NSRange) {
        let marker = (markedQuery as NSString).range(of: "¦")
        return (markedQuery.replacingOccurrences(of: "¦", with: ""), NSRange(location: marker.location, length: 0))
    }

    private func matches(_ query: String, name: String = "Task", projects: [String] = [], tags: [String] = []) throws -> Bool {
        let rawID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let task = try TodoTask(
            id: TaskID(rawValue: rawID), relativePath: "tasks/\(rawID).md", name: name, state: "doing",
            projectSlugs: projects, tags: tags, dueDate: nil, recurrence: nil, recurrenceFrom: nil,
            lastCompletedDate: nil, body: "", extraProperties: []
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = TaskDateContext(referenceDate: Date(timeIntervalSince1970: 1_788_566_400), calendar: calendar)
        return try TaskFilterQuery(query).matches(task, terminalStateIDs: ["archived"], dates: dates)
    }
}
