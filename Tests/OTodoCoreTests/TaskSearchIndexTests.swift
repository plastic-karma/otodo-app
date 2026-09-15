import Foundation
import XCTest
@testable import OTodoCore

final class TaskSearchIndexTests: XCTestCase {
    func testTermsMatchAcrossFieldsWithCaseDiacriticAndWhitespaceFolding() throws {
        let task = try makeTask(name: "Résumé café", projects: ["work-app"], tags: ["Urgént"], body: "Review naïve approach")
        let other = try makeTask(id: 2, name: "Résumé café", body: "Review other approach")
        let project = try TodoProject(slug: "work-app", relativePath: "Projects/work-app.md", name: "Équipe mobile")
        let index = TaskSearchIndex(tasks: [task, other], projects: [project.slug: project])
        XCTAssertEqual(index.tasks(matching: "  RESUME\tnaive\nurgent ÉQUIPE  "), [task])
        XCTAssertEqual(index.tasks(matching: "WORK-APP cafe"), [task])
        XCTAssertTrue(index.tasks(matching: "résumé missing").isEmpty)
        XCTAssertTrue(index.tasks(matching: " \t\n ").isEmpty)
    }

    func testCompletedSubtasksAndUncachedProjectSlugsAreSearchableWithoutParentMatches() throws {
        let parent = try makeTask(name: "Unrelated parent")
        var child = try makeTask(id: 2, name: "Unique child", projects: ["uncached-project"], body: "needle")
        child.parentID = parent.id
        child.state = "done"
        let index = TaskSearchIndex(tasks: [parent, child], projects: [:])
        XCTAssertEqual(index.tasks(matching: "needle uncached-project"), [child])
        XCTAssertTrue(index.tasks(matching: "Unrelated needle").isEmpty)
    }

    func testSearchTreatsFilterAndRegexSyntaxAsLiteralText() throws {
        let task = try makeTask(name: "Fix [a-z]+ AND parser", body: "tag:home")
        let other = try makeTask(id: 2, name: "Fix parser", tags: ["home"])
        let index = TaskSearchIndex(tasks: [task, other], projects: [:])
        XCTAssertEqual(index.tasks(matching: "[a-z]+ AND tag:home"), [task])
        XCTAssertTrue(index.tasks(matching: "name:/Fix/").isEmpty)
    }

    private func makeTask(
        id number: Int = 1, name: String, projects: [String] = [], tags: [String] = [], body: String = ""
    ) throws -> TodoTask {
        let id = try TaskID(rawValue: String(repeating: "0", count: 25) + String(number))
        return try TodoTask(
            id: id, relativePath: "Tasks/\(id.rawValue).md", name: name, state: "open",
            projectSlugs: projects, tags: tags, dueDate: nil,
            recurrence: nil, recurrenceFrom: nil, lastCompletedDate: nil,
            body: body, extraProperties: []
        )
    }
}
