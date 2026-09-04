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
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Active todos due today or overdue.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: TodayWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 8) {
            header

            if entry.tasks.isEmpty {
                emptyState
            } else if family == .systemSmall {
                compactContent
            } else {
                taskList
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

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.headline)
            Text("TODAY")
                .font(.caption.weight(.bold))
                .tracking(0.8)
            Spacer(minLength: 4)
            Text("\(entry.tasks.count)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.18), in: Capsule())
        }
    }

    private var emptyState: some View {
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

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(entry.tasks.count)")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(entry.tasks.count == 1 ? "todo needs focus" : "todos need focus")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
            Spacer(minLength: 0)
            if let task = entry.tasks.first {
                Text(task.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .privacySensitive()
                Text(dueLabel(for: task))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.76))
            }
        }
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 6) {
            ForEach(Array(entry.tasks.prefix(rowLimit))) { task in
                taskRow(task)
            }
            if entry.tasks.count > rowLimit {
                Text("+\(entry.tasks.count - rowLimit) more")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.76))
            }
            Spacer(minLength: 0)
        }
    }

    private func taskRow(_ task: TodayWidgetTask) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: task.dueDate < entry.todayKey ? "exclamationmark.circle.fill" : "circle.fill")
                .font(.caption)
                .foregroundStyle(task.dueDate < entry.todayKey ? Color.yellow : Color.white.opacity(0.85))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .privacySensitive()
                Text(dueLabel(for: task))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private var rowLimit: Int {
        family == .systemLarge ? 7 : 3
    }

    private func dueLabel(for task: TodayWidgetTask) -> String {
        let day = task.dueDate < entry.todayKey ? "Overdue" : "Due today"
        guard let dueTime = task.dueTime else { return day }
        return "\(day) · \(dueTime)"
    }
}

@main
struct OTodoWidgetBundle: WidgetBundle {
    var body: some Widget {
        OTodoTodayWidget()
    }
}
