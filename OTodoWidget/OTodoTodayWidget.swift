import OTodoCore
import SwiftUI
import WidgetKit

struct TodayWidgetEntry: TimelineEntry {
    let date: Date
    let todayKey: String
    let tasks: [TodayWidgetTask]
}

struct TodayWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayWidgetEntry {
        TodayWidgetEntry(
            date: .now,
            todayKey: "2026-09-04",
            tasks: [
                TodayWidgetTask(
                    id: "preview-1",
                    name: "Review the launch plan",
                    dueDate: "2026-09-04",
                    dueTime: "09:30"
                ),
                TodayWidgetTask(
                    id: "preview-2",
                    name: "Send status update",
                    dueDate: "2026-09-03",
                    dueTime: nil
                ),
            ]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayWidgetEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(for: .now))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<TodayWidgetEntry>) -> Void
    ) {
        let now = Date.now
        let startOfToday = Calendar.autoupdatingCurrent.startOfDay(for: now)
        let nextMidnight = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: 1,
            to: startOfToday
        ) ?? now.addingTimeInterval(24 * 60 * 60)
        completion(Timeline(entries: [entry(for: now)], policy: .after(nextMidnight)))
    }

    private func entry(for date: Date) -> TodayWidgetEntry {
        let todayKey = TodayWidgetSnapshotBuilder.dateKey(for: date)
        let tasks = TodayWidgetStorage.load()?.tasks(dueOnOrBefore: todayKey) ?? []
        return TodayWidgetEntry(date: date, todayKey: todayKey, tasks: tasks)
    }
}

struct OTodoTodayWidget: Widget {
    let kind = TodayWidgetStorage.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayWidgetProvider()) { entry in
            TodayWidgetView(todayKey: entry.todayKey, tasks: entry.tasks)
                .fontDesign(.rounded)
        }
        .configurationDisplayName("Today")
        .description("Active todos due today or overdue.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let todayKey: String
    let tasks: [TodayWidgetTask]

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 8) {
            TodayWidgetHeader(count: tasks.count)

            if tasks.isEmpty {
                TodayWidgetEmptyState()
            } else if family == .systemSmall, let task = tasks.first {
                TodayWidgetCompactContent(count: tasks.count, name: task.name, dueTime: task.dueTime, overdue: task.dueDate < todayKey)
            } else {
                TodayWidgetTaskList(tasks: tasks, todayKey: todayKey, isLarge: family == .systemLarge)
            }
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(red: 0.25, green: 0.18, blue: 0.67),
                    Color(red: 0.49, green: 0.24, blue: 0.78),
                    Color(red: 0.88, green: 0.30, blue: 0.60),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

}

private struct TodayWidgetHeader: View {
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.headline)
            Text("TODAY")
                .font(.caption.weight(.bold))
                .tracking(0.8)
            Spacer(minLength: 4)
            Text(count, format: .number)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.18), in: Capsule())
        }
    }

}

private struct TodayWidgetEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "sparkles")
                .font(.title2.weight(.semibold))
            Text("All clear")
                .font(.headline)
            Text("No active todos are due.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
            Spacer(minLength: 0)
        }
    }

}

private struct TodayWidgetCompactContent: View {
    let count: Int
    let name: String
    let dueTime: String?
    let overdue: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(count, format: .number)
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(focusMessage)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
            Spacer(minLength: 0)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .privacySensitive()
            TodayWidgetDueLabel(overdue: overdue, dueTime: dueTime)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.76))
        }
    }

    private var focusMessage: LocalizedStringKey {
        count == 1 ? "todo needs focus" : "todos need focus"
    }
}

private struct TodayWidgetTaskList: View {
    let tasks: [TodayWidgetTask]
    let todayKey: String
    let isLarge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isLarge ? 8 : 6) {
            ForEach(tasks.prefix(rowLimit)) { task in
                TodayWidgetTaskRow(name: task.name, dueTime: task.dueTime, overdue: task.dueDate < todayKey)
            }
            if tasks.count > rowLimit {
                Text("+\(tasks.count - rowLimit, format: .number) more")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.76))
            }
            Spacer(minLength: 0)
        }
    }

    private var rowLimit: Int {
        isLarge ? 7 : 3
    }
}

private struct TodayWidgetTaskRow: View {
    let name: String
    let dueTime: String?
    let overdue: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: overdue ? "exclamationmark.circle.fill" : "circle.fill")
                .font(.caption)
                .foregroundStyle(overdue ? Color.yellow : Color.white.opacity(0.85))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .privacySensitive()
                TodayWidgetDueLabel(overdue: overdue, dueTime: dueTime)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

}

private struct TodayWidgetDueLabel: View {
    let overdue: Bool
    let dueTime: String?

    var body: some View {
        if let dueTime {
            if overdue {
                Text("Overdue · \(dueTime)")
            } else {
                Text("Due today · \(dueTime)")
            }
        } else {
            Text(dayLabel)
        }
    }

    private var dayLabel: LocalizedStringKey {
        overdue ? "Overdue" : "Due today"
    }
}

@main
struct OTodoWidgetBundle: WidgetBundle {
    var body: some Widget {
        OTodoTodayWidget()
    }
}
