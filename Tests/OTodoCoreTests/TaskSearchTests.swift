import XCTest
@testable import OTodoCore

final class TaskSearchTests: XCTestCase {
    func testMatchesEveryRecognizableTextFieldWithCaseAndDiacriticFolding() throws {
        let task = try TodoTask(
            id: TaskID(rawValue: "01ARZ3NDEKTSV4RRFFQ69G5FAV"),
            relativePath: "todos/01ARZ3NDEKTSV4RRFFQ69G5FAV.md",
            name: "Résumé invoice",
            state: "todo",
            projectSlugs: ["home-office"],
            tags: ["Urgent"],
            dueDate: nil,
            recurrence: nil,
            recurrenceFrom: nil,
            lastCompletedDate: nil,
            body: "Acme reference 123",
            extraProperties: [],
            url: "https://example.com/billing"
        )

        XCTAssertTrue(TaskSearch("resume 123").matches(task))
        XCTAssertTrue(TaskSearch("HOME-office urgent").matches(task))
        XCTAssertTrue(TaskSearch("example.com/billing").matches(task))
        XCTAssertTrue(TaskSearch("q69g5fav").matches(task))
        XCTAssertFalse(TaskSearch("invoice missing").matches(task))
    }

    func testBlankQueryMatchesWithoutFiltering() throws {
        let task = try TodoTask(
            id: TaskID(rawValue: "01ARZ3NDEKTSV4RRFFQ69G5FAV"),
            relativePath: "todos/01ARZ3NDEKTSV4RRFFQ69G5FAV.md",
            name: "Any todo",
            state: "todo",
            projectSlugs: [],
            tags: [],
            dueDate: nil,
            recurrence: nil,
            recurrenceFrom: nil,
            lastCompletedDate: nil,
            body: "",
            extraProperties: []
        )

        let search = TaskSearch(" \n\t ")
        XCTAssertTrue(search.isEmpty)
        XCTAssertTrue(search.matches(task))
    }
}
