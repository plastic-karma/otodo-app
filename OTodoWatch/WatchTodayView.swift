import OTodoCore
import SwiftUI

struct WatchTodayView: View {
    let receiver: WatchSnapshotReceiver
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            // Minute boundaries include local midnight, even while the phone is offline.
            TimelineView(.periodic(from: Calendar.current.startOfDay(for: .now), by: 60)) { context in
                WatchTodayList(receiver: receiver, dateKey: TodayWidgetSnapshotBuilder.dateKey(for: context.date))
            }
            .navigationTitle("OTodo")
            .navigationDestination(for: String.self) { identifier in
                if let workspace = receiver.workspace, workspace.workspaceAvailable,
                   let task = workspace.snapshot.tasks.first(where: { $0.id == identifier }) {
                    WatchTaskDetail(name: task.name, dueDate: task.dueDate, dueTime: task.dueTime)
                } else {
                    ContentUnavailableView("Task unavailable", systemImage: "checkmark.circle", description: Text("Return to Today for the latest todos."))
                }
            }
            .onOpenURL { url in
                guard url.scheme == "otodo-watch", url.host == "today" else { return }
                path.removeAll()
                receiver.refresh()
            }
            .onChange(of: receiver.workspace?.workspaceAvailable) { _, available in
                if available != true { path.removeAll() }
            }
        }
    }
}

private struct WatchTodayList: View {
    let receiver: WatchSnapshotReceiver
    let dateKey: String

    var body: some View {
        List {
            if let workspace = receiver.workspace {
                if workspace.workspaceAvailable {
                    let day = workspace.day(on: dateKey)
                    Section {
                        Text("\(day.totalCount, format: .number) due or overdue")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                    }
                    WatchTaskSection(tasks: day.overdue, overdue: true)
                    WatchTaskSection(tasks: day.today, overdue: false)
                } else {
                    Section("Set up on iPhone") {
                        Text("Open OTodo on your paired iPhone, sign in, and select a workspace.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Section("Waiting for iPhone") {
                    Text("Open OTodo on your paired iPhone to send your Today and Overdue todos. Your last received list will then be available offline.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            WatchSyncSection(receiver: receiver)
        }
        .listStyle(.carousel)
    }
}

private struct WatchTaskSection: View {
    let tasks: [TodayWidgetTask]
    let overdue: Bool

    var body: some View {
        Section {
            if tasks.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tasks) { task in
                    NavigationLink(value: task.id) {
                        WatchTaskRow(name: task.name, dueDate: task.dueDate, dueTime: task.dueTime, overdue: overdue)
                    }
                }
            }
        } header: {
            if overdue {
                Text("Overdue · \(tasks.count, format: .number)")
            } else {
                Text("Today · \(tasks.count, format: .number)")
            }
        }
    }

    private var emptyMessage: LocalizedStringKey {
        overdue ? "Nothing overdue" : "Nothing due today"
    }
}

private struct WatchTaskRow: View {
    let name: String
    let dueDate: String
    let dueTime: String?
    let overdue: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name)
                .font(.headline)
                .lineLimit(3)
            Text(WatchTaskDetail.schedule(dueDate: dueDate, dueTime: dueTime))
                .font(.caption)
                .foregroundStyle(overdue ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Opens the full task name and schedule")
    }

    private var accessibilityDescription: Text {
        let schedule = Text(WatchTaskDetail.schedule(dueDate: dueDate, dueTime: dueTime))
        return overdue ? Text("\(name), overdue, \(schedule)") : Text("\(name), today, \(schedule)")
    }
}

private struct WatchSyncSection: View {
    let receiver: WatchSnapshotReceiver

    var body: some View {
        Section("Sync") {
            if let workspace = receiver.workspace {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved on Watch")
                    Text(workspace.snapshot.generatedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                        .foregroundStyle(.secondary)
                    Text("Shows the last information received from iPhone.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error = receiver.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !receiver.isReachable {
                Text("iPhone is unavailable. Saved todos still roll forward each day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                receiver.refresh()
            } label: {
                Label(refreshTitle, systemImage: "arrow.clockwise")
            }
            .disabled(receiver.isRequesting)
        }
    }

    private var refreshTitle: LocalizedStringKey {
        receiver.isRequesting ? "Refreshing…" : "Refresh from iPhone"
    }
}

private struct WatchTaskDetail: View {
    let name: String
    let dueDate: String
    let dueTime: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Due date")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(dueDate)
                    Text("Due time")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    if let dueTime {
                        Text(dueTime)
                    } else {
                        Text("No time set")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .privacySensitive()
        }
        .navigationTitle("Task")
    }

    static func schedule(dueDate: String, dueTime: String?) -> LocalizedStringKey {
        if let dueTime { return "\(dueDate) at \(dueTime)" }
        return "\(dueDate) · No time set"
    }
}
