import Foundation
import OTodoCore
import SwiftUI

enum DailyReviewKind: String, CaseIterable, Identifiable {
    case kickstart
    case wrapUp

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .kickstart: "Morning review"
        case .wrapUp: "Evening review"
        }
    }

    var closingTitle: LocalizedStringKey {
        switch self {
        case .kickstart: "You’re in motion."
        case .wrapUp: "The day is closed."
        }
    }

    var startTitle: LocalizedStringKey {
        switch self {
        case .kickstart: "Start morning review"
        case .wrapUp: "Start evening review"
        }
    }

    var finishTitle: LocalizedStringKey {
        switch self {
        case .kickstart: "Finish morning review"
        case .wrapUp: "Finish evening review"
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
        case .kickstart: OTodoTheme.coral
        case .wrapUp: OTodoTheme.accent
        }
    }
}

extension DailyReviewKind {
    var filledTint: Color {
        switch self {
        case .kickstart: Color(red: 0.48, green: 0.24, blue: 0.08)
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
    // Acknowledging the shared introduction is separate from finishing either review.
    static let introductionAcknowledgedKey = "daily-review.introduction-acknowledged"

    static func reset(_ defaults: UserDefaults = .standard) {
        for key in [
            kickstartEnabledKey, wrapUpEnabledKey, kickstartTimeKey, wrapUpTimeKey,
            kickstartCompletedKey, wrapUpCompletedKey, introductionAcknowledgedKey,
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let kind: DailyReviewKind
    let taskCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: OTodoTheme.Spacing.small) {
                Image(systemName: kind.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(kind == .kickstart ? OTodoTheme.warmForeground : OTodoTheme.accent)
                    .accessibilityHidden(true)

                let labelLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: OTodoTheme.Spacing.small))
                labelLayout {
                    Text("Daily review")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(taskCount == 1 ? "1 task" : "\(taskCount) tasks")
                        .font(.subheadline)
                        .foregroundStyle(OTodoTheme.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OTodoTheme.secondaryText)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, OTodoTheme.Spacing.inset)
            .padding(.vertical, 4)
            .background(OTodoTheme.card, in: RoundedRectangle(cornerRadius: OTodoTheme.Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Daily review")
        .accessibilityValue(taskCount == 1 ? "1 task" : "\(taskCount) tasks")
        .accessibilityHint("Starts the daily review")
        .accessibilityIdentifier("daily-review-prompt-\(kind.rawValue)")
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
                        Text("OTodo surfaces each enabled review on Today after its chosen time. Open Daily review anytime to start one manually.")
                            .font(.subheadline)
                            .foregroundStyle(OTodoTheme.secondaryText)
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
            .navigationTitle("Daily review")
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
            .foregroundStyle(kind == .kickstart ? OTodoTheme.warmForeground : OTodoTheme.accent)
            .frame(width: 48, height: 48)
            .background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: OTodoTheme.Radius.control))
    }

    private func reviewSetting(
        kind: DailyReviewKind,
        isEnabled: Binding<Bool>,
        time: Binding<Date>,
        detail: LocalizedStringKey
    ) -> some View {
        Section {
            Toggle(isOn: isEnabled) {
                Label(kind.title, systemImage: kind.icon)
                    .font(.headline)
            }
            .tint(kind.filledTint)
            .accessibilityIdentifier("daily-review-\(kind.rawValue)-enabled")

            if isEnabled.wrappedValue {
                DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("daily-review-\(kind.rawValue)-time")
                Button(kind.startTitle) {
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

private struct DailyReviewIntroduction: View {
    let kind: DailyReviewKind
    let taskCount: Int
    let completedToday: Int
    let isHelp: Bool
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OTodoTheme.Spacing.section) {
                Image(systemName: kind.icon)
                    .font(.title.weight(.medium))
                    .foregroundStyle(kind == .kickstart ? OTodoTheme.warmForeground : OTodoTheme.accent)
                    .frame(width: 52, height: 52)
                    .background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: OTodoTheme.Radius.control))
                    .accessibilityHidden(true)

                Text(kind.title)
                    .font(.title.bold())
                    .foregroundStyle(.primary)
                Text(summary)
                    .font(.body)
                    .foregroundStyle(OTodoTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button(continueTitle, action: onContinue)
                    .buttonStyle(OTodoPrimaryButtonStyle())
                    .accessibilityIdentifier(isHelp ? "daily-review-help-return" : "daily-review-begin")
            }
            .padding(OTodoTheme.Spacing.section)
            .frame(maxWidth: 560, alignment: .leading)
            .background(kind.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: OTodoTheme.Radius.card))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("daily-review-summary-opening")
            .padding(OTodoTheme.Spacing.inset)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var continueTitle: LocalizedStringKey {
        if isHelp { return "Return to review" }
        return taskCount == 0 ? "See summary" : "Start review"
    }

    private var summary: LocalizedStringKey {
        guard taskCount > 0 else {
            return completedToday > 0
                ? "Your due list is clear. \(completedToday) completed today."
                : "Your due list is clear. Take a moment to plan what comes next."
        }
        return taskCount == 1
            ? "One task to review. Keep for today leaves its schedule unchanged, including an overdue date. You can also reschedule it or mark it done."
            : "\(taskCount) tasks to review. Keep for today leaves each schedule unchanged, including overdue dates. You can also reschedule or mark each task done."
    }
}

struct DailyReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct ReschedulePresentation: Identifiable {
        let task: TodoTask
        var id: TaskID { task.id }
    }

    private struct SessionTask: Identifiable {
        let task: TodoTask
        let position: Int
        var id: TaskID { task.id }
    }

    let kind: DailyReviewKind
    private let completedTodayAtStart: Int
    private let onComplete: @MainActor (TodoTask) async -> String?
    private let onReschedule: @MainActor (
        [TodoTask], TaskDueDateChange, TaskDueTimeChange
    ) async -> String?
    private let onFinish: () -> Void

    @State private var sessionTasks: [SessionTask]
    @State private var showsIntroduction: Bool
    @State private var showsHelp = false
    @State private var page = 1
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
        _showsIntroduction = State(
            initialValue: !UserDefaults.standard.bool(
                forKey: DailyReviewPreferences.introductionAcknowledgedKey
            )
        )
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
        _sessionTasks = State(initialValue: reviewTasks.enumerated().map {
            SessionTask(task: $0.element, position: $0.offset + 1)
        })
        completedTodayAtStart = tasks.lazy.filter { $0.lastCompletedDate == today }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OTodoCanvas()
                if showsIntroduction {
                    DailyReviewIntroduction(
                        kind: kind,
                        taskCount: sessionTasks.count,
                        completedToday: completedTodayAtStart,
                        isHelp: false
                    ) {
                        UserDefaults.standard.set(
                            true, forKey: DailyReviewPreferences.introductionAcknowledgedKey
                        )
                        showsIntroduction = false
                    }
                } else {
                    TabView(selection: $page) {
                        ForEach(sessionTasks) { entry in
                            taskCard(entry.task, position: entry.position)
                                .tag(entry.position)
                        }
                        closingCard
                            .tag(sessionTasks.count + 1)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("daily-review-\(kind.rawValue)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isActing)
                        .accessibilityIdentifier("daily-review-close")
                }
                if !showsIntroduction {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Review help", systemImage: "questionmark.circle") {
                            showsHelp = true
                        }
                        .disabled(isActing)
                        .accessibilityIdentifier("daily-review-help")
                    }
                }
            }
            .sheet(isPresented: $showsHelp) {
                NavigationStack {
                    DailyReviewIntroduction(
                        kind: kind,
                        taskCount: sessionTasks.count,
                        completedToday: completedTodayAtStart,
                        isHelp: true
                    ) {
                        showsHelp = false
                    }
                    .background(OTodoTheme.formCanvas.ignoresSafeArea())
                    .navigationTitle("Daily review")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsHelp = false }
                                .accessibilityIdentifier("daily-review-help-close")
                        }
                    }
                }
                .presentationDetents([.large])
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

    private var reviewForeground: Color {
        kind == .kickstart ? OTodoTheme.warmForeground : OTodoTheme.accent
    }

    private var closingCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OTodoTheme.Spacing.section) {
                Image(systemName: "checkmark.seal")
                    .font(.title.weight(.medium))
                    .foregroundStyle(reviewForeground)
                    .frame(width: 52, height: 52)
                    .background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: OTodoTheme.Radius.control))
                    .accessibilityHidden(true)

                Text(kind.closingTitle)
                    .font(.title.bold())
                    .foregroundStyle(.primary)

                Text(closingSummary)
                    .font(.body)
                    .foregroundStyle(OTodoTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button(kind.finishTitle) { onFinish() }
                    .buttonStyle(OTodoPrimaryButtonStyle())
                    .accessibilityIdentifier("daily-review-finish")
            }
            .padding(OTodoTheme.Spacing.section)
            .frame(maxWidth: 560, alignment: .leading)
            .background(kind.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: OTodoTheme.Radius.card))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("daily-review-summary-closing")
            .padding(OTodoTheme.Spacing.inset)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func taskCard(_ task: TodoTask, position: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OTodoTheme.Spacing.section) {
                let headerLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 12))
                headerLayout {
                    Label(dueDescription(task), systemImage: dueIcon(task))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(reviewForeground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Review · \(position) of \(sessionTasks.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(OTodoTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("daily-review-progress")
                }

                Text(task.name)
                    .font(.title.bold())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !task.projectSlugs.isEmpty {
                    Label(task.projectSlugs.joined(separator: ", "), systemImage: "folder")
                        .font(.subheadline)
                        .foregroundStyle(OTodoTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !task.tags.isEmpty {
                    Text(task.tags.map { "@\($0)" }.joined(separator: "  "))
                        .font(.subheadline)
                        .foregroundStyle(OTodoTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !task.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(task.body)
                        .font(.body)
                        .foregroundStyle(OTodoTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
                    VStack(spacing: OTodoTheme.Spacing.small) {
                        Button("Keep for today", systemImage: "arrow.right") {
                            affirmedCount += 1
                            advance(from: task)
                        }
                        .buttonStyle(OTodoPrimaryButtonStyle())
                        .accessibilityHint("Leaves the task and its current schedule unchanged and moves to the next todo")
                        .accessibilityIdentifier("daily-review-keep-\(task.id.rawValue)")

                        let actionLayout = dynamicTypeSize >= .xxxLarge
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                            : AnyLayout(HStackLayout(spacing: 8))
                        actionLayout {
                            Button("Mark done", systemImage: "checkmark.circle") {
                                complete(task)
                            }
                            .buttonStyle(OTodoChipStyle())
                            .accessibilityIdentifier("daily-review-done-\(task.id.rawValue)")

                            Button("Reschedule", systemImage: "calendar") {
                                actionError = nil
                                reschedulePresentation = ReschedulePresentation(task: task)
                            }
                            .buttonStyle(OTodoChipStyle())
                            .accessibilityIdentifier("daily-review-reschedule-\(task.id.rawValue)")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(OTodoTheme.Spacing.section)
            .frame(maxWidth: 560, alignment: .leading)
            .background(OTodoTheme.card, in: RoundedRectangle(cornerRadius: OTodoTheme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: OTodoTheme.Radius.card)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("daily-review-task-\(task.id.rawValue)")
            .padding(OTodoTheme.Spacing.inset)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }


    private var closingSummary: LocalizedStringKey {
        if sessionTasks.isEmpty {
            return kind == .kickstart
                ? "Nothing overdue. Start with the space you made."
                : "Nothing is waiting for a decision. Rest easy."
        }
        return "\(completedCount) finished, \(rescheduledCount) rescheduled, and \(affirmedCount) kept."
    }

    private func dueDescription(_ task: TodoTask) -> String {
        guard let dueDate = task.dueDate else { return "No date" }
        let today = TaskSchedule.civilDate(from: .now)
        let label: String
        if dueDate == today {
            label = "Today"
        } else {
            label = TaskSchedule.date(from: dueDate, time: nil)
                .formatted(.dateTime.month(.abbreviated).day().locale(locale))
        }
        if let dueTime = task.dueTime {
            return "\(label) · \(TaskSchedule.date(from: dueDate, time: dueTime).formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)))"
        }
        return label
    }

    private func dueIcon(_ task: TodoTask) -> String {
        guard let dueDate = task.dueDate, let today = TaskSchedule.civilDate(from: .now) else {
            return "calendar"
        }
        return dueDate.rawValue < today.rawValue ? "exclamationmark.circle.fill" : "calendar.circle.fill"
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
        withAnimation(reduceMotion || task != nil ? nil : .easeOut(duration: 0.2)) {
            page = min(target, sessionTasks.count + 1)
        }
    }
}

