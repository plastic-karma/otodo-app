import Foundation

/// The companion shares only active task names and schedules, never credentials or task bodies.
public struct WatchWorkspaceSnapshot: Sendable, Codable, Equatable {
    public let version: Int
    public let workspaceAvailable: Bool
    public let snapshot: TodayWidgetSnapshot

    public init(snapshot: TodayWidgetSnapshot, workspaceAvailable: Bool) {
        version = 1
        self.workspaceAvailable = workspaceAvailable
        self.snapshot = snapshot
    }

    public func day(on dateKey: String) -> WatchDaySnapshot {
        var today: [TodayWidgetTask] = []
        var overdue: [TodayWidgetTask] = []
        if workspaceAvailable {
            for task in snapshot.tasks {
                if task.dueDate < dateKey {
                    overdue.append(task)
                } else if task.dueDate == dateKey {
                    today.append(task)
                }
            }
        }
        return WatchDaySnapshot(today: today, overdue: overdue)
    }

    private enum CodingKeys: String, CodingKey {
        case version, workspaceAvailable, snapshot
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw OTodoError.corruptLocalState(message: "Unsupported Apple Watch snapshot version")
        }
        self.init(
            snapshot: try container.decode(TodayWidgetSnapshot.self, forKey: .snapshot),
            workspaceAvailable: try container.decode(Bool.self, forKey: .workspaceAvailable)
        )
    }
}

public struct WatchDaySnapshot: Sendable, Equatable {
    public let today: [TodayWidgetTask]
    public let overdue: [TodayWidgetTask]
    public var totalCount: Int { today.count + overdue.count }

    public init(today: [TodayWidgetTask], overdue: [TodayWidgetTask]) {
        self.today = today
        self.overdue = overdue
    }
}
