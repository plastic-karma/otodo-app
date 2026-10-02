import OTodoCore
import SwiftUI

struct StatsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var model: AppModel
    @State private var weekOffset = 0

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if let configuration = model.configuration {
                    let selected = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: context.date) ?? context.date
                    let stats = TaskStatistics(
                        tasks: model.tasks, configuration: configuration,
                        containing: selected, now: context.date, calendar: calendar
                    )
                    dashboard(stats, calendar: calendar)
                } else {
                    ContentUnavailableView("No workspace", systemImage: "chart.bar", description: Text("Open a workspace to see its statistics."))
                }
            }
            .background(OTodoTheme.formCanvas.ignoresSafeArea())
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("stats-close")
                }
            }
            .tint(OTodoTheme.accent)
        }
    }

    private func dashboard(_ stats: TaskStatistics, calendar: Calendar) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text(weekOffset == 0 ? "This week" : "Weekly review")
                        .font(.title2.bold())
                    Text("\(stats.week.start, format: dateStyle) – \(calendar.date(byAdding: .day, value: -1, to: stats.week.end)!, format: dateStyle)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("stats-week-range")
                    let navigationLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                        : AnyLayout(HStackLayout(spacing: 12))
                    navigationLayout {
                        Button { weekOffset -= 1 } label: {
                            Label("Previous", systemImage: "chevron.left")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                            .accessibilityLabel("Previous week")
                            .accessibilityIdentifier("stats-previous-week")
                        Button { weekOffset = 0 } label: {
                            Text("This week")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                            .disabled(weekOffset == 0)
                            .accessibilityIdentifier("stats-current-week")
                        Button { weekOffset += 1 } label: {
                            Image(systemName: "chevron.right")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                            .accessibilityLabel("Next week")
                            .disabled(weekOffset >= 0)
                            .accessibilityIdentifier("stats-next-week")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 8)
            }
            .listRowBackground(OTodoTheme.card)

            Section {
                StatisticsMetric(title: "Finished total", value: "\(stats.finished, format: .number)", symbol: "checkmark.circle.fill", id: "stats-finished")
                StatisticsMetric(title: "Finished on time", value: "\(stats.finishedOnTime, format: .number) of \(stats.assessedDatedCompletions, format: .number)", symbol: "clock.badge.checkmark", id: "stats-on-time")
                StatisticsMetric(title: "Created", value: "\(stats.created, format: .number)", symbol: "plus.circle.fill", id: "stats-created")
            } header: {
                Text("Recorded this week")
            } footer: {
                Text("Finished counts recorded completions, including recurring occurrences and recompletions. On time compares the schedule saved before completion; date-only tasks allow the whole day. \(stats.undatedCompletions) undated and \(stats.unassessedDatedCompletions) unassessable completions are excluded from the on-time denominator. Created uses each retained task’s ULID creation timestamp.")
            }
            .listRowBackground(OTodoTheme.card)

            if stats.finished == 0 && stats.created == 0 {
                ContentUnavailableView("No recorded activity", systemImage: "chart.bar", description: Text("Create or complete a todo to start a weekly review. Older completion history may be unknown."))
                    .listRowBackground(Color.clear)
            }

            Section {
                StatisticsRanking(title: "Projects", emptyTitle: "No ranked projects", entries: stats.activeProjects)
                StatisticsRanking(title: "Labels", emptyTitle: "No ranked labels", entries: stats.activeTags)
            } header: { Text("Most active this week") } footer: {
                Text("One activity per creation or recorded completion, per project or label. Completion categories are snapshots; creation categories use the task’s current metadata. Unassigned activity has no ranking. Top five shown in each ranking.")
            }
            .listRowBackground(OTodoTheme.card)

            Section {
                StatisticsRanking(title: "Projects", emptyTitle: "No ranked projects", entries: stats.currentOverdueProjects)
                StatisticsRanking(title: "Labels", emptyTitle: "No ranked labels", entries: stats.currentOverdueTags)
            } header: { Text("Most overdue · now") } footer: {
                Text("Current nonterminal tasks past their due date or exact due time, not historical overdue counts for the selected week. Each task counts once per project or label.")
            }
            .listRowBackground(OTodoTheme.card)

            Section {
                StatisticsFeature(title: "Subtasks", completed: stats.completedFeatureUsage.subtasks, current: stats.currentFeatureUsage.subtasks)
                StatisticsFeature(title: "Attachments", completed: stats.completedFeatureUsage.attachments, current: stats.currentFeatureUsage.attachments)
                StatisticsFeature(title: "Recurring", completed: stats.completedFeatureUsage.recurring, current: stats.currentFeatureUsage.recurring)
            } header: { Text("Advanced features") } footer: {
                Text("Weekly counts are completed occurrences using each feature at completion; current counts are retained tasks using it now. Subtasks includes children and parents with children. Attachments means at least one recognized local attachment link in the notes, not a verified downloaded file. Categories can overlap.")
            }
            .listRowBackground(OTodoTheme.card)

            Section("History coverage") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Based on \(stats.retainedTasks) retained tasks in this workspace, including offline changes. Not a complete Git history.")
                    if let earliest = stats.earliestRecordedCompletion {
                        Text("Earliest retained completion evidence: \(earliest, format: dateStyle.hour().minute()). This is not a guarantee of continuous coverage.")
                    } else {
                        Text("No completion evidence recorded yet. Previous completions are unknown, not zero.")
                    }
                    Text("\(stats.legacyCompletedTasks) completed or previously recurring tasks have no readable completion evidence. \(stats.unknownHistoryEntries) unsupported history entries are excluded and preserved.")
                    Text("Completions are recorded by this version of OTodo. Imported legacy completions are never backdated; deletions, external edits, and conflict choices can reduce retained evidence. Calendar weeks follow your device’s calendar and time zone.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("stats-coverage")
            }
            .listRowBackground(OTodoTheme.card)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(OTodoTheme.formCanvas.ignoresSafeArea())
        .accessibilityIdentifier("stats-list")
    }

    private var dateStyle: Date.FormatStyle {
        Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: calendar, timeZone: calendar.timeZone)
            .locale(locale)
    }
}

private struct StatisticsMetric: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: LocalizedStringKey
    let value: LocalizedStringKey
    let symbol: String
    let id: String

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
        layout {
            Label(title, systemImage: symbol)
                .foregroundStyle(OTodoTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.title2.weight(.semibold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(id)
    }

}

private struct StatisticsRanking: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: LocalizedStringKey
    let emptyTitle: LocalizedStringKey
    let entries: [TaskStatistics.Ranking]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.bold())
            if entries.isEmpty {
                Text(emptyTitle).foregroundStyle(.secondary)
            } else {
                ForEach(entries.prefix(5)) { entry in
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
                    layout {
                        Text(entry.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(entry.count, format: .number)
                            .font(.body.weight(.semibold))
                            .fontDesign(.rounded)
                            .monospacedDigit()
                            .foregroundStyle(OTodoTheme.accent)
                            .fixedSize()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.vertical, 4)
    }

}

private struct StatisticsFeature: View {
    let title: LocalizedStringKey
    let completed: Int
    let current: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold())
            Text("\(completed) completed this week · \(current) tasks now")
                .font(.subheadline).foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
