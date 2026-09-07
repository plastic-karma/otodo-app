import OTodoCore
import SwiftUI

struct StatsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State private var weekOffset = 0

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if let configuration = model.configuration {
                    let calendar = Calendar.autoupdatingCurrent
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
                    Text("\(stats.week.start.formatted(date: .abbreviated, time: .omitted)) – \(calendar.date(byAdding: .day, value: -1, to: stats.week.end)!.formatted(date: .abbreviated, time: .omitted))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("stats-week-range")
                    HStack {
                        Button { weekOffset -= 1 } label: { Label("Previous", systemImage: "chevron.left") }
                            .accessibilityLabel("Previous week")
                            .accessibilityIdentifier("stats-previous-week")
                        Spacer(minLength: 8)
                        Button("This week") { weekOffset = 0 }
                            .disabled(weekOffset == 0)
                            .accessibilityIdentifier("stats-current-week")
                        Button { weekOffset += 1 } label: { Image(systemName: "chevron.right") }
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
                metric("Finished total", value: "\(stats.finished)", symbol: "checkmark.circle.fill", id: "stats-finished")
                metric("Finished on time", value: "\(stats.finishedOnTime) of \(stats.assessedDatedCompletions)", symbol: "clock.badge.checkmark", id: "stats-on-time")
                metric("Created", value: "\(stats.created)", symbol: "plus.circle.fill", id: "stats-created")
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
                ranking("Projects", entries: stats.activeProjects)
                ranking("Labels", entries: stats.activeTags)
            } header: { Text("Most active this week") } footer: {
                Text("One activity per creation or recorded completion, per project or label. Completion categories are snapshots; creation categories use the task’s current metadata. Unassigned activity has no ranking. Top five shown in each ranking.")
            }
            .listRowBackground(OTodoTheme.card)

            Section {
                ranking("Projects", entries: stats.currentOverdueProjects)
                ranking("Labels", entries: stats.currentOverdueTags)
            } header: { Text("Most overdue · now") } footer: {
                Text("Current nonterminal tasks past their due date or exact due time, not historical overdue counts for the selected week. Each task counts once per project or label.")
            }
            .listRowBackground(OTodoTheme.card)

            Section {
                feature("Subtasks", completed: stats.completedFeatureUsage.subtasks, current: stats.currentFeatureUsage.subtasks)
                feature("Attachments", completed: stats.completedFeatureUsage.attachments, current: stats.currentFeatureUsage.attachments)
                feature("Recurring", completed: stats.completedFeatureUsage.recurring, current: stats.currentFeatureUsage.recurring)
            } header: { Text("Advanced features") } footer: {
                Text("Weekly counts are completed occurrences using each feature at completion; current counts are retained tasks using it now. Subtasks includes children and parents with children. Attachments means at least one recognized local attachment link in the notes, not a verified downloaded file. Categories can overlap.")
            }
            .listRowBackground(OTodoTheme.card)

            Section("History coverage") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Based on \(stats.retainedTasks) retained tasks in this workspace, including offline changes. Not a complete Git history.")
                    if let earliest = stats.earliestRecordedCompletion {
                        Text("Earliest retained completion evidence: \(earliest.formatted(date: .abbreviated, time: .shortened)). This is not a guarantee of continuous coverage.")
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
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("stats-list")
    }

    private func metric(_ title: String, value: String, symbol: String, id: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Label(title, systemImage: symbol).foregroundStyle(OTodoTheme.accent)
                Spacer()
                Text(value).font(.title2.bold()).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol).foregroundStyle(OTodoTheme.accent)
                Text(value).font(.title2.bold()).monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(id)
    }

    private func ranking(_ title: String, entries: [TaskStatistics.Ranking]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.bold())
            if entries.isEmpty {
                Text("No ranked \(title.lowercased())").foregroundStyle(.secondary)
            } else {
                ForEach(entries.prefix(5)) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.name)
                        Spacer()
                        Text(entry.count.formatted()).monospacedDigit().foregroundStyle(OTodoTheme.accent)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func feature(_ title: String, completed: Int, current: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold())
            Text("\(completed) completed this week · \(current) tasks now")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
