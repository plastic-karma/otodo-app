import OTodoCore
import SwiftUI
import WidgetKit

private enum WatchComplicationState {
    case waiting
    case setup
    case unreadable
    case ready(WatchDaySnapshot)
}

private struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let state: WatchComplicationState
}

private struct WatchComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(date: .now, state: .waiting)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchComplicationEntry) -> Void) {
        let date = Date.now
        do {
            completion(entry(at: date, workspace: try WatchSnapshotStorage.load()))
        } catch {
            completion(WatchComplicationEntry(date: date, state: .unreadable))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchComplicationEntry>) -> Void) {
        let now = Date.now
        do {
            let workspace = try WatchSnapshotStorage.load()
            var entries = [entry(at: now, workspace: workspace)]
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .autoupdatingCurrent
            var midnight = calendar.startOfDay(for: now)
            // A week of local-only entries survives deferred reloads. Calendar day
            // arithmetic, not 86,400 seconds, preserves midnight across DST.
            for _ in 0..<8 {
                guard let next = calendar.date(byAdding: .day, value: 1, to: midnight) else { break }
                midnight = calendar.startOfDay(for: next)
                entries.append(entry(at: midnight, workspace: workspace))
            }
            completion(Timeline(entries: entries, policy: .atEnd))
        } catch {
            completion(Timeline(
                entries: [WatchComplicationEntry(date: now, state: .unreadable)],
                policy: .after(now.addingTimeInterval(15 * 60))
            ))
        }
    }

    private func entry(at date: Date, workspace: WatchWorkspaceSnapshot?) -> WatchComplicationEntry {
        guard let workspace else { return WatchComplicationEntry(date: date, state: .waiting) }
        guard workspace.workspaceAvailable else { return WatchComplicationEntry(date: date, state: .setup) }
        return WatchComplicationEntry(
            date: date,
            state: .ready(workspace.day(on: TodayWidgetSnapshotBuilder.dateKey(for: date)))
        )
    }
}

private struct WatchComplicationView: View {
    let state: WatchComplicationState

    var body: some View {
        Group {
            switch state {
            case .ready(let day):
                let firstTask = day.overdue.first ?? day.today.first
                WatchComplicationReadyContent(
                    todayCount: day.today.count,
                    overdueCount: day.overdue.count,
                    taskName: firstTask?.name,
                    dueDate: firstTask?.dueDate,
                    dueTime: firstTask?.dueTime
                )
            case .waiting:
                WatchComplicationStatus(title: "Open OTodo", detail: "Waiting for iPhone", symbol: "iphone")
            case .setup:
                WatchComplicationStatus(title: "Set up OTodo", detail: "Open OTodo on iPhone", symbol: "iphone")
            case .unreadable:
                WatchComplicationStatus(title: "Open OTodo", detail: "Refresh saved todos", symbol: "arrow.clockwise")
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(URL(string: "otodo-watch://today"))
        .privacySensitive()
    }

}

private struct WatchComplicationReadyContent: View {
    @Environment(\.widgetFamily) private var family
    let todayCount: Int
    let overdueCount: Int
    let taskName: String?
    let dueDate: String?
    let dueTime: String?

    private var totalCount: Int { todayCount + overdueCount }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label {
                if totalCount == 0 {
                    Text("OTodo: all clear")
                } else {
                    Text("\(todayCount, format: .number) today · \(overdueCount, format: .number) overdue")
                }
            } icon: {
                Image(systemName: "checklist")
            }
            .accessibilityLabel(summary)
        case .accessoryCorner:
            Text(totalCount, format: .number)
                .font(.title2.bold())
                .widgetAccentable()
                .widgetLabel {
                    if totalCount == 0 {
                        Text("All clear")
                    } else {
                        Text("\(todayCount, format: .number) today · \(overdueCount, format: .number) overdue")
                    }
                }
                .accessibilityLabel(summary)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: totalCount == 0 ? "checkmark" : "checklist")
                        .font(.caption)
                    Text(totalCount, format: .number)
                        .font(.title2.bold())
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
                .widgetAccentable()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text("\(todayCount, format: .number) today · \(overdueCount, format: .number) overdue")
                    .font(.headline)
                    .widgetAccentable()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let taskName {
                    Text(taskName)
                        .font(.caption)
                        .lineLimit(2)
                    schedule
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text("All clear")
                        .font(.caption)
                    Text("No todos due or overdue")
                        .font(.caption2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rectangularDescription)
        }
    }

    private var summary: Text {
        Text("OTodo. \(totalCount, format: .number) todos due or overdue. \(todayCount, format: .number) today. \(overdueCount, format: .number) overdue. Opens the saved task list.")
    }

    private var rectangularDescription: Text {
        guard let taskName else { return summary }
        return Text("OTodo. \(totalCount, format: .number) todos due or overdue. \(todayCount, format: .number) today. \(overdueCount, format: .number) overdue. Opens the saved task list. \(taskName). \(schedule).")
    }

    private var schedule: Text {
        if overdueCount > 0, let dueDate {
            if let dueTime { return Text("\(dueDate) at \(dueTime)") }
            return Text("\(dueDate) · No time set")
        }
        if let dueTime { return Text("Today at \(dueTime)") }
        return Text("Today · No time set")
    }
}

private struct WatchComplicationStatus: View {
    @Environment(\.widgetFamily) private var family
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let symbol: String

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(detail, systemImage: symbol)
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.title2)
                .widgetLabel { Text(title) }
                .accessibilityLabel("\(Text(title)). \(Text(detail))")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol)
                    .font(.title2)
            }
            .accessibilityLabel("\(Text(title)). \(Text(detail))")
        default:
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .widgetAccentable()
                Text(detail)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

private struct OTodoWatchTodayWidget: Widget {
    let kind = WatchSnapshotStorage.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchComplicationProvider()) { entry in
            WatchComplicationView(state: entry.state)
                .fontDesign(.rounded)
        }
        .configurationDisplayName("Today & Overdue")
        .description("Saved todos from your iPhone, updated for today even while offline.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct OTodoWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        OTodoWatchTodayWidget()
    }
}
