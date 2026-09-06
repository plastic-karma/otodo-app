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
    @Environment(\.widgetFamily) private var family
    let entry: WatchComplicationEntry

    var body: some View {
        Group {
            switch entry.state {
            case .ready(let day):
                readyContent(day)
            case .waiting:
                statusContent("Open OTodo", detail: "Waiting for iPhone", symbol: "iphone")
            case .setup:
                statusContent("Set up OTodo", detail: "Open OTodo on iPhone", symbol: "iphone")
            case .unreadable:
                statusContent("Open OTodo", detail: "Refresh saved todos", symbol: "arrow.clockwise")
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(URL(string: "otodo-watch://today"))
        .privacySensitive()
    }

    @ViewBuilder
    private func readyContent(_ day: WatchDaySnapshot) -> some View {
        switch family {
        case .accessoryInline:
            Label(day.totalCount == 0 ? "OTodo: all clear" : "\(day.today.count) today · \(day.overdue.count) overdue", systemImage: "checklist")
                .accessibilityLabel(summary(day))
        case .accessoryCorner:
            Text("\(day.totalCount)")
                .font(.title2.bold())
                .widgetAccentable()
                .widgetLabel {
                    Text(day.totalCount == 0 ? "All clear" : "\(day.today.count) today · \(day.overdue.count) overdue")
                }
                .accessibilityLabel(summary(day))
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: day.totalCount == 0 ? "checkmark" : "checklist")
                        .font(.caption)
                    Text("\(day.totalCount)")
                        .font(.title2.bold())
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
                .widgetAccentable()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary(day))
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text("\(day.today.count) today · \(day.overdue.count) overdue")
                    .font(.headline)
                    .widgetAccentable()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let task = day.overdue.first ?? day.today.first {
                    Text(task.name)
                        .font(.caption)
                        .lineLimit(2)
                    Text(schedule(task, overdue: !day.overdue.isEmpty))
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
            .accessibilityLabel(rectangularDescription(day))
        }
    }

    @ViewBuilder
    private func statusContent(_ title: String, detail: String, symbol: String) -> some View {
        switch family {
        case .accessoryInline:
            Label(detail, systemImage: symbol)
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.title2)
                .widgetLabel { Text(title) }
                .accessibilityLabel("\(title). \(detail)")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol)
                    .font(.title2)
            }
            .accessibilityLabel("\(title). \(detail)")
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

    private func summary(_ day: WatchDaySnapshot) -> String {
        "OTodo. \(day.totalCount) todos due or overdue. \(day.today.count) today. \(day.overdue.count) overdue. Opens the saved task list."
    }

    private func rectangularDescription(_ day: WatchDaySnapshot) -> String {
        guard let task = day.overdue.first ?? day.today.first else { return summary(day) }
        return "\(summary(day)) \(task.name). \(schedule(task, overdue: !day.overdue.isEmpty))."
    }

    private func schedule(_ task: TodayWidgetTask, overdue: Bool) -> String {
        let date = overdue ? task.dueDate : "Today"
        if let time = task.dueTime { return "\(date) at \(time)" }
        return "\(date) · No time set"
    }
}

private struct OTodoWatchTodayWidget: Widget {
    let kind = WatchSnapshotStorage.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchComplicationProvider()) { entry in
            WatchComplicationView(entry: entry)
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
