import Foundation
import OTodoCore
import SwiftUI

enum DailyReviewKind: String, CaseIterable, Identifiable {
    case kickstart
    case wrapUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kickstart: "Kickstart"
        case .wrapUp: "Wrap-up"
        }
    }

    var promptTitle: String {
        switch self {
        case .kickstart: "Start with intention"
        case .wrapUp: "Close the day clearly"
        }
    }

    var introTitle: String {
        switch self {
        case .kickstart: "Today, clearly."
        case .wrapUp: "Close the loop."
        }
    }

    var closingTitle: String {
        switch self {
        case .kickstart: "You’re in motion."
        case .wrapUp: "The day is closed."
        }
    }

    var icon: String {
        switch self {
        case .kickstart: "sunrise.fill"
        case .wrapUp: "moon.stars.fill"
        }
    }

    var defaultMinutes: Int {
        switch self {
        case .kickstart: 8 * 60
        case .wrapUp: 17 * 60
        }
    }

    var tint: Color {
        switch self {
        case .kickstart: OTodoTheme.gold
        case .wrapUp: OTodoTheme.filledViolet
        }
    }
}

enum DailyReviewPreferences {
    static let kickstartEnabledKey = "daily-review.kickstart-enabled"
    static let wrapUpEnabledKey = "daily-review.wrap-up-enabled"
    static let kickstartTimeKey = "daily-review.kickstart-minutes"
    static let wrapUpTimeKey = "daily-review.wrap-up-minutes"
    static let kickstartCompletedKey = "daily-review.kickstart-completed-date"
    static let wrapUpCompletedKey = "daily-review.wrap-up-completed-date"

    static func reset(_ defaults: UserDefaults = .standard) {
        for key in [
            kickstartEnabledKey, wrapUpEnabledKey, kickstartTimeKey, wrapUpTimeKey,
            kickstartCompletedKey, wrapUpCompletedKey,
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    static func dayStamp(for date: Date, calendar: Calendar = TaskSchedule.calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0, components.month ?? 0, components.day ?? 0
        )
    }

    static func minutesSinceMidnight(
        for date: Date, calendar: Calendar = TaskSchedule.calendar
    ) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    static func promptedKind(
        at date: Date,
        kickstartEnabled: Bool,
        wrapUpEnabled: Bool,
        kickstartMinutes: Int,
        wrapUpMinutes: Int,
        kickstartCompleted: String,
        wrapUpCompleted: String
    ) -> DailyReviewKind? {
        let stamp = dayStamp(for: date)
        let minutes = minutesSinceMidnight(for: date)
        if wrapUpEnabled, minutes >= wrapUpMinutes, wrapUpCompleted != stamp {
            return .wrapUp
        }
        if kickstartEnabled, minutes >= kickstartMinutes,
           (!wrapUpEnabled || minutes < wrapUpMinutes), kickstartCompleted != stamp
        {
            return .kickstart
        }
        return nil
    }
}

struct DailyReviewPromptCard: View {
    let kind: DailyReviewKind
    let taskCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: kind.icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(kind.tint, in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.promptTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(promptDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 4)

                Image(systemName: "arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(kind.tint)
            }
            .padding(16)
            .background(OTodoTheme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.title) ready")
        .accessibilityValue(taskCount == 1 ? "One todo" : "\(taskCount) todos")
        .accessibilityHint("Starts the daily review")
        .accessibilityIdentifier("daily-review-prompt-\(kind.rawValue)")
    }

    private var promptDetail: String {
        switch taskCount {
        case 0: "Your due list is clear."
        case 1: "One todo is ready for a decision."
        default: "\(taskCount) todos are ready for a decision."
        }
    }
}

struct DailyReviewSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DailyReviewPreferences.kickstartEnabledKey) private var kickstartEnabled = false
    @AppStorage(DailyReviewPreferences.wrapUpEnabledKey) private var wrapUpEnabled = false
    @AppStorage(DailyReviewPreferences.kickstartTimeKey) private var kickstartMinutes = DailyReviewKind.kickstart.defaultMinutes
    @AppStorage(DailyReviewPreferences.wrapUpTimeKey) private var wrapUpMinutes = DailyReviewKind.wrapUp.defaultMinutes

    let onStart: (DailyReviewKind) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            rhythmIcon(.kickstart)
                            rhythmIcon(.wrapUp)
                        }
                        Text("A calm beginning. A clean ending.")
                            .font(.title2.bold())
                        Text("OTodo surfaces each enabled check-in on Today after its chosen time. Open Daily rhythm anytime to start one manually.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                }

                reviewSetting(
                    kind: .kickstart,
                    isEnabled: $kickstartEnabled,
                    time: timeBinding(minutes: $kickstartMinutes),
                    detail: "See what is due or overdue, then give every todo a clear next move."
                )

                reviewSetting(
                    kind: .wrapUp,
                    isEnabled: $wrapUpEnabled,
                    time: timeBinding(minutes: $wrapUpMinutes),
                    detail: "Celebrate what moved and decide what should not follow you into tomorrow."
                )
            }
            .scrollContentBackground(.hidden)
            .background(OTodoTheme.formCanvas.ignoresSafeArea())
            .navigationTitle("Daily rhythm")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("daily-review-settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func rhythmIcon(_ kind: DailyReviewKind) -> some View {
        Image(systemName: kind.icon)
            .font(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(kind.tint, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func reviewSetting(
        kind: DailyReviewKind,
        isEnabled: Binding<Bool>,
        time: Binding<Date>,
        detail: String
    ) -> some View {
        Section {
            Toggle(isOn: isEnabled) {
                Label(kind.title, systemImage: kind.icon)
                    .font(.headline)
            }
            .tint(kind.tint)
            .accessibilityIdentifier("daily-review-\(kind.rawValue)-enabled")

            if isEnabled.wrappedValue {
                DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("daily-review-\(kind.rawValue)-time")
                Button("Start \(kind.title) now") {
                    onStart(kind)
                }
                .foregroundStyle(kind.tint)
                .accessibilityIdentifier("daily-review-start-\(kind.rawValue)")
            }
        } footer: {
            Text(detail)
        }
    }

    private func timeBinding(minutes: Binding<Int>) -> Binding<Date> {
        Binding {
            TaskSchedule.calendar.date(
                byAdding: .minute,
                value: minutes.wrappedValue,
                to: TaskSchedule.calendar.startOfDay(for: .now)
            ) ?? .now
        } set: { date in
            minutes.wrappedValue = DailyReviewPreferences.minutesSinceMidnight(for: date)
        }
    }
}

struct DailyReviewView: View {
    @Environment(\.dismiss) private var dismiss
    private struct ReschedulePresentation: Identifiable {
        let task: TodoTask
        var id: TaskID { task.id }
    }

    let kind: DailyReviewKind
    private let completedTodayAtStart: Int
    private let onComplete: @MainActor (TodoTask) async -> String?
    private let onReschedule: @MainActor (
        [TodoTask], TaskDueDateChange, TaskDueTimeChange
    ) async -> String?
    private let onFinish: () -> Void

    @State private var sessionTasks: [TodoTask]
    @State private var page = 0
    @State private var completedCount = 0
    @State private var rescheduledCount = 0
    @State private var affirmedCount = 0
    @State private var isActing = false
    @State private var actionError: String?
    @State private var reschedulePresentation: ReschedulePresentation?

    init(
        kind: DailyReviewKind,
        tasks: [TodoTask],
        states: [WorkflowState],
        onComplete: @escaping @MainActor (TodoTask) async -> String?,
        onReschedule: @escaping @MainActor (
            [TodoTask], TaskDueDateChange, TaskDueTimeChange
        ) async -> String?,
        onFinish: @escaping () -> Void
    ) {
        self.kind = kind
        self.onComplete = onComplete
        self.onReschedule = onReschedule
        self.onFinish = onFinish
        let today = TaskSchedule.civilDate(from: .now)
        let terminalStates = Set(states.lazy.filter(\.isTerminal).map(\.id))
        let reviewTasks = tasks.filter { task in
            !terminalStates.contains(task.state) && task.dueDate.map { dueDate in
                guard let today else { return false }
                return dueDate.rawValue <= today.rawValue
            } == true
        }.sorted { lhs, rhs in
            if lhs.dueDate != rhs.dueDate {
                return (lhs.dueDate?.rawValue ?? "") < (rhs.dueDate?.rawValue ?? "")
            }
            if lhs.dueTime != rhs.dueTime {
                return (lhs.dueTime?.rawValue ?? "") < (rhs.dueTime?.rawValue ?? "")
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        _sessionTasks = State(initialValue: reviewTasks)
        completedTodayAtStart = tasks.lazy.filter { $0.lastCompletedDate == today }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OTodoCanvas()
                TabView(selection: $page) {
                    summaryCard(isClosing: false)
                        .tag(0)
                    ForEach(Array(sessionTasks.enumerated()), id: \.element.id) { offset, task in
                        taskCard(task, position: offset + 1)
                            .tag(offset + 1)
                    }
                    summaryCard(isClosing: true)
                        .tag(sessionTasks.count + 1)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .padding(.vertical, 8)
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("daily-review-\(kind.rawValue)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isActing)
                }
            }
            .sheet(item: $reschedulePresentation) { presentation in
                TaskRescheduleView(tasks: [presentation.task]) { date, time in
                    let error = await onReschedule([presentation.task], date, time)
                    if error == nil {
                        rescheduledCount += 1
                        advance(from: presentation.task)
                    }
                    return error
                }
                .presentationDetents([.large])
            }
        }
    }

    private func summaryCard(isClosing: Bool) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: isClosing ? "checkmark.seal.fill" : kind.icon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 21, style: .continuous))

                Text(isClosing ? kind.closingTitle : kind.introTitle)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                Text(isClosing ? closingSummary : openingSummary)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 12)

                if isClosing {
                    Button("Finish \(kind.title)") { onFinish() }
                        .buttonStyle(DailyReviewPrimaryButtonStyle())
                        .accessibilityIdentifier("daily-review-finish")
                } else {
                    Button(sessionTasks.isEmpty ? "See the summary" : "Let’s go") {
                        advance()
                    }
                    .buttonStyle(DailyReviewPrimaryButtonStyle())
                    .accessibilityIdentifier("daily-review-begin")
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: 600, alignment: .leading)
            .background(summaryGradient, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .shadow(color: kind.tint.opacity(0.22), radius: 22, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(isClosing ? "daily-review-summary-closing" : "daily-review-summary-opening")
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 20)
    }

    private func taskCard(_ task: TodoTask, position: Int) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(dueDescription(task), systemImage: dueIcon(task))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(kind.tint)
                    Spacer()
                    Text("\(position) of \(sessionTasks.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(task.name)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !task.projectSlugs.isEmpty || !task.tags.isEmpty {
                    Text(metadata(for: task))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !task.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(task.body)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }

                Spacer(minLength: 8)

                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("daily-review-action-error")
                }

                if isActing {
                    ProgressView("Saving your decision…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 10) {
                        Button("Done", systemImage: "checkmark.circle.fill") {
                            complete(task)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(OTodoTheme.mint)
                        .accessibilityIdentifier("daily-review-done-\(task.id.rawValue)")

                        Button("Reschedule", systemImage: "calendar.badge.clock") {
                            actionError = nil
                            reschedulePresentation = ReschedulePresentation(task: task)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("daily-review-reschedule-\(task.id.rawValue)")
                    }

                    Button("LFG", systemImage: "arrow.right") {
                        affirmedCount += 1
                        advance(from: task)
                    }
                    .buttonStyle(DailyReviewPrimaryButtonStyle())
                    .accessibilityHint("Affirms this todo and moves to the next card")
                    .accessibilityIdentifier("daily-review-lfg-\(task.id.rawValue)")
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, maxHeight: 600, alignment: .leading)
            .background(OTodoTheme.card, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(kind.tint.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("daily-review-task-\(task.id.rawValue)")
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 20)
    }

    private var summaryGradient: LinearGradient {
        switch kind {
        case .kickstart:
            LinearGradient(
                colors: [OTodoTheme.coral, OTodoTheme.gold],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .wrapUp:
            OTodoTheme.heroGradient
        }
    }

    private var openingSummary: String {
        let completion = completedTodayAtStart == 1
            ? "One todo is already done today."
            : "\(completedTodayAtStart) todos are already done today."
        guard !sessionTasks.isEmpty else {
            return kind == .kickstart
                ? "Your due list is clear. \(completion) Begin with the space you made."
                : "\(completion) Nothing due needs to follow you into tomorrow."
        }
        let queue = sessionTasks.count == 1
            ? "One due todo deserves a decision."
            : "\(sessionTasks.count) due todos deserve a decision."
        switch kind {
        case .kickstart: return "\(queue) \(completion) Keep, move, or finish each one."
        case .wrapUp: return "\(completion) \(queue) Decide what leaves with you and what moves forward."
        }
    }

    private var closingSummary: String {
        if sessionTasks.isEmpty {
            return kind == .kickstart
                ? "Nothing overdue. Start with the space you made."
                : "Nothing is waiting for a decision. Rest easy."
        }
        let completed = completedCount == 1 ? "1 finished" : "\(completedCount) finished"
        let rescheduled = rescheduledCount == 1 ? "1 rescheduled" : "\(rescheduledCount) rescheduled"
        let affirmed = affirmedCount == 1 ? "1 affirmed" : "\(affirmedCount) affirmed"
        return "\(completed), \(rescheduled), and \(affirmed). Every card got your attention."
    }

    private func dueDescription(_ task: TodoTask) -> String {
        guard let dueDate = task.dueDate else { return "No date" }
        let today = TaskSchedule.civilDate(from: .now)
        let label: String
        if dueDate == today {
            label = "Today"
        } else {
            label = TaskSchedule.date(from: dueDate, time: nil)
                .formatted(.dateTime.month(.abbreviated).day())
        }
        if let dueTime = task.dueTime {
            return "\(label) · \(TaskSchedule.date(from: dueDate, time: dueTime).formatted(date: .omitted, time: .shortened))"
        }
        return label
    }

    private func dueIcon(_ task: TodoTask) -> String {
        guard let dueDate = task.dueDate, let today = TaskSchedule.civilDate(from: .now) else {
            return "calendar"
        }
        return dueDate.rawValue < today.rawValue ? "exclamationmark.circle.fill" : "calendar.circle.fill"
    }

    private func metadata(for task: TodoTask) -> String {
        let projects = task.projectSlugs.map { "#\($0)" }
        let tags = task.tags.map { "@\($0)" }
        return (projects + tags).joined(separator: "  ")
    }

    private func complete(_ task: TodoTask) {
        actionError = nil
        isActing = true
        Task { @MainActor in
            let error = await onComplete(task)
            isActing = false
            if let error {
                actionError = error
            } else {
                completedCount += 1
                advance(from: task)
            }
        }
    }

    private func advance(from task: TodoTask? = nil) {
        let target: Int
        if let task, let index = sessionTasks.firstIndex(where: { $0.id == task.id }) {
            target = index + 2
        } else {
            target = min(page + 1, sessionTasks.count + 1)
        }
        withAnimation(.snappy(duration: 0.28)) {
            page = min(target, sessionTasks.count + 1)
        }
    }
}

private struct DailyReviewPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(OTodoTheme.filledAccent)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(.white.opacity(configuration.isPressed ? 0.78 : 0.94))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}
