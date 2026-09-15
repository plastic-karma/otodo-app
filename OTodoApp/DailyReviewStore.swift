import Foundation
import Observation
import OTodoCore

@MainActor
@Observable
final class DailyReviewStore {
    static let shared = DailyReviewStore()
    private static let defaultsKey = "daily-review.workspaces.v1"

    private struct Workspace: Codable {
        var morning = DailyReviewPreference(kind: .morning)
        var evening = DailyReviewPreference(kind: .evening)
        var sessions: [String: DailyReviewSession] = [:]
    }

    private var workspaces: [String: Workspace] = [:]
    private(set) var errorMessage: String?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-testing") && arguments.contains("-ui-testing-reset-workspace") {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
#endif
        if let data = defaults.data(forKey: Self.defaultsKey) {
            do {
                workspaces = try JSONDecoder().decode([String: Workspace].self, from: data)
            } catch {
                errorMessage = "Saved daily reviews could not be read. Your todos are unaffected. \(error.localizedDescription)"
            }
        }
    }

    func preference(_ kind: DailyReviewKind, workspace: String) -> DailyReviewPreference {
        let value = workspaces[workspace] ?? Workspace()
        return kind == .morning ? value.morning : value.evening
    }

    @discardableResult
    func setPreference(_ preference: DailyReviewPreference, kind: DailyReviewKind, workspace: String) -> Bool {
        var value = workspaces[workspace] ?? Workspace()
        if kind == .morning { value.morning = preference } else { value.evening = preference }
        return save(value, workspace: workspace)
    }

    func session(_ kind: DailyReviewKind, workspace: String, summary: DailyReviewSummary) -> DailyReviewSession {
        if let saved = workspaces[workspace]?.sessions[kind.rawValue], saved.day == summary.day {
            return saved
        }
        return DailyReviewSession(summary: summary)
    }

    @discardableResult
    func saveSession(_ session: DailyReviewSession, kind: DailyReviewKind, workspace: String) -> Bool {
        var value = workspaces[workspace] ?? Workspace()
        value.sessions[kind.rawValue] = session
        return save(value, workspace: workspace)
    }

    func finish(_ session: DailyReviewSession, kind: DailyReviewKind, workspace: String) -> Bool {
        guard session.page == session.pageCount - 1 else { return false }
        var value = workspaces[workspace] ?? Workspace()
        if kind == .morning { value.morning.reviewedDays.insert(session.day) }
        else { value.evening.reviewedDays.insert(session.day) }
        value.sessions.removeValue(forKey: kind.rawValue)
        return save(value, workspace: workspace)
    }

    private func save(_ value: Workspace, workspace: String) -> Bool {
        var updated = workspaces
        updated[workspace] = value
        do {
            let data = try JSONEncoder().encode(updated)
            defaults.set(data, forKey: Self.defaultsKey)
            workspaces = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Daily review progress could not be saved. \(error.localizedDescription)"
            return false
        }
    }
}

extension DailyReviewKind {
    var title: String { self == .morning ? "Kickstart" : "Wrap up" }
    var symbol: String { self == .morning ? "sunrise.fill" : "moon.stars.fill" }
    var invitation: String {
        self == .morning ? "Make room for what matters today." : "Notice your wins. Give tomorrow some space."
    }
}
