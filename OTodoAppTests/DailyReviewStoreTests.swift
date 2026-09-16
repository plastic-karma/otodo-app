import Foundation
import OTodoCore
import XCTest
@testable import OTodo

@MainActor
final class DailyReviewStoreTests: XCTestCase {
    func testIncompleteReviewResumesButOnlyFinalAcknowledgmentSuppressesWorkspacePrompt() throws {
        let suite = "DailyReviewStoreTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DailyReviewStore(defaults: defaults)
        let first = DailyReviewContext.workspaceKey(try WorkspaceSelection(owner: "test", name: "todos", branch: "main", storePath: "Todo"))
        let other = DailyReviewContext.workspaceKey(try WorkspaceSelection(owner: "test", name: "todos", branch: "other", storePath: "Todo"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-15T10:00:00Z"))
        let summary = DailyReviewSummary(tasks: [], terminalStateIDs: ["done"], at: now, calendar: calendar)
        var preference = store.preference(.morning, workspace: first)
        preference.isEnabled = true
        preference.minuteOfDay = 9 * 60 + 30
        XCTAssertTrue(store.setPreference(preference, kind: .morning, workspace: first))
        XCTAssertTrue(store.setPreference(preference, kind: .morning, workspace: other))
        var session = store.session(.morning, workspace: first, summary: summary)
        session.page = 1
        XCTAssertTrue(store.saveSession(session, kind: .morning, workspace: first))
        XCTAssertFalse(store.finish(session, kind: .morning, workspace: first))
        let reopened = DailyReviewStore(defaults: defaults)
        XCTAssertEqual(reopened.session(.morning, workspace: first, summary: summary).page, 1)
        XCTAssertEqual(reopened.preference(.morning, workspace: first).minuteOfDay, 9 * 60 + 30)
        XCTAssertTrue(reopened.preference(.morning, workspace: first).isDue(kind: .morning, at: now, calendar: calendar))
        session.page = session.pageCount - 1
        XCTAssertTrue(reopened.finish(session, kind: .morning, workspace: first))
        let finished = DailyReviewStore(defaults: defaults)
        XCTAssertFalse(finished.preference(.morning, workspace: first).isDue(kind: .morning, at: now, calendar: calendar))
        XCTAssertTrue(finished.preference(.morning, workspace: other).isDue(kind: .morning, at: now, calendar: calendar))
        XCTAssertFalse(finished.preference(.evening, workspace: first).reviewedDays.contains(summary.day))
        XCTAssertEqual(finished.session(.morning, workspace: first, summary: summary).page, 0, "Manual replay starts a new deck")
        let tomorrow = DailyReviewSummary(tasks: [], terminalStateIDs: ["done"], at: now.addingTimeInterval(86_400), calendar: calendar)
        XCTAssertEqual(finished.session(.morning, workspace: first, summary: tomorrow).day, "2026-09-16")
    }

    func testWorkspaceKeysDoNotCollideForBranchAndStorePathBoundaries() throws {
        let first = try WorkspaceSelection(owner: "test", name: "todos", branch: "topic/a", storePath: "b")
        let second = try WorkspaceSelection(owner: "test", name: "todos", branch: "topic", storePath: "a/b")
        XCTAssertNotEqual(DailyReviewContext.workspaceKey(first), DailyReviewContext.workspaceKey(second))
    }
}
