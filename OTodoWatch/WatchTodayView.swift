import OTodoCore
import SwiftUI

struct WatchTodayView: View {
    @Bindable var receiver: WatchSnapshotReceiver
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            // Minute boundaries include local midnight, even while the phone is offline.
            TimelineView(.periodic(from: Calendar.current.startOfDay(for: .now), by: 60)) { context in
                mainList(on: context.date)
            }
            .navigationTitle("OTodo")
            .navigationDestination(for: String.self) { identifier in
                if let workspace = receiver.workspace, workspace.workspaceAvailable,
                   let task = workspace.snapshot.tasks.first(where: { $0.id == identifier }) {
                    WatchTaskDetail(task: task)
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

    @ViewBuilder
    private func mainList(on date: Date) -> some View {
        List {
            if let workspace = receiver.workspace {
                if workspace.workspaceAvailable {
                    let day = workspace.day(on: TodayWidgetSnapshotBuilder.dateKey(for: date))
                    Section {
                        Text("\(day.totalCount) due or overdue")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                    }
                    taskSection("Overdue", tasks: day.overdue, overdue: true)
                    taskSection("Today", tasks: day.today, overdue: false)
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
            syncSection
        }
        .listStyle(.carousel)
    }

    private func taskSection(_ title: String, tasks: [TodayWidgetTask], overdue: Bool) -> some View {
        Section("\(title) · \(tasks.count)") {
            if tasks.isEmpty {
                Text(overdue ? "Nothing overdue" : "Nothing due today")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tasks) { task in
                    NavigationLink(value: task.id) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(task.name)
                                .font(.headline)
                                .lineLimit(3)
                            Text(WatchTaskDetail.schedule(for: task))
                                .font(.caption)
                                .foregroundStyle(overdue ? Color.orange : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .privacySensitive()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(task.name), \(overdue ? "overdue" : "today"), \(WatchTaskDetail.schedule(for: task))")
                        .accessibilityHint("Opens the full task name and schedule")
                    }
                }
            }
        }
    }

    private var syncSection: some View {
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
                Label(receiver.isRequesting ? "Refreshing…" : "Refresh from iPhone", systemImage: "arrow.clockwise")
            }
            .disabled(receiver.isRequesting)
        }
    }
}

private struct WatchTaskDetail: View {
    let task: TodayWidgetTask

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(task.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Due date")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(task.dueDate)
                    Text("Due time")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    Text(task.dueTime ?? "No time set")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .privacySensitive()
        }
        .navigationTitle("Task")
    }

    static func schedule(for task: TodayWidgetTask) -> String {
        if let time = task.dueTime { return "\(task.dueDate) at \(time)" }
        return "\(task.dueDate) · No time set"
    }
}
