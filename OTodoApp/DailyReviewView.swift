import OTodoCore
import SwiftUI

struct DailyReviewView: View {
    let model: AppModel
    let request: DailyReviewRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var store = DailyReviewStore.shared
    @State private var session: DailyReviewSession
    @State private var isSaving = false
    @State private var didFinish = false
    @State private var actionError: String?
    @State private var reschedule: RescheduleRequest?

    private struct RescheduleRequest: Identifiable {
        let task: TodoTask
        var id: TaskID { task.id }
    }

    init(model: AppModel, request: DailyReviewRequest) {
        self.model = model
        self.request = request
        let summary = DailyReviewSummary(
            tasks: model.tasks,
            terminalStateIDs: Set(model.configuration?.states.filter(\.isTerminal).map(\.id) ?? []),
            at: request.date
        )
        _session = State(initialValue: DailyReviewStore.shared.session(
            request.kind, workspace: DailyReviewContext.workspaceKey(request.selection), summary: summary
        ))
    }

    private var workspace: String { DailyReviewContext.workspaceKey(request.selection) }
    private var kind: DailyReviewKind { request.kind }
    private var terminalStates: Set<String> { Set(model.configuration?.states.filter(\.isTerminal).map(\.id) ?? []) }
    private var accent: Color { kind == .morning ? OTodoTheme.accent : OTodoTheme.violet }
    private var summary: DailyReviewSummary {
        DailyReviewSummary(tasks: model.tasks, terminalStateIDs: terminalStates, at: request.date)
    }

    var body: some View {
        let currentSummary = summary
        NavigationStack {
            VStack(spacing: 12) {
                progress
                TabView(selection: $session.page) {
                    opening(currentSummary).tag(0)
                    ForEach(Array(session.tasks.enumerated()), id: \.element.id) { index, reference in
                        taskCard(reference).tag(index + 1)
                    }
                    reflection(currentSummary).tag(session.tasks.count + 1)
                    closing(currentSummary).tag(session.pageCount - 1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .disabled(isSaving)
                if let message = actionError ?? store.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 24)
                        .accessibilityIdentifier("daily-review-error")
                }
                navigation
            }
            .padding(.top, 12)
            .background(OTodoTheme.formCanvas.ignoresSafeArea())
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { persist(); dismiss() }
                        .disabled(isSaving)
                        .accessibilityHint("Keeps your place without marking this review finished.")
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onChange(of: session.page) { _, _ in persist() }
            .onChange(of: model.workspaceSelection) { _, selection in
                if selection != request.selection { dismiss() }
            }
            .onAppear { persist() }
            .onDisappear { persist() }
            .sheet(item: $reschedule) { request in
                TaskRescheduleView(tasks: [request.task]) { dueDate, dueTime in
                    await saveSchedule(request.task, dueDate: dueDate, dueTime: dueTime)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView("Saving on this device…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
        .tint(accent)
        .accessibilityIdentifier("daily-review")
    }

    private var progress: some View {
        VStack(spacing: 8) {
            HStack {
                Label(request.date.formatted(date: .abbreviated, time: .omitted), systemImage: kind.symbol)
                Spacer()
                Text("\(session.page + 1) of \(session.pageCount)").monospacedDigit()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            ProgressView(value: Double(session.page + 1), total: Double(session.pageCount))
                .tint(accent)
                .accessibilityLabel("Review progress")
                .accessibilityValue("Card \(session.page + 1) of \(session.pageCount)")
        }
        .padding(.horizontal, 24)
    }

    private var navigation: some View {
        HStack {
            Button { move(by: -1) } label: {
                Label("Back", systemImage: "chevron.left").frame(minHeight: 44)
            }
                .disabled(session.page == 0 || isSaving)
                .accessibilityIdentifier("daily-review-back")
            Spacer()
            if !dynamicTypeSize.isAccessibilitySize {
                Text("Swipe or use Next")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer()
            }
            Button { move(by: 1) } label: {
                Label("Next", systemImage: "chevron.right").frame(minHeight: 44)
            }
                .disabled(session.page == session.pageCount - 1 || isSaving)
                .accessibilityIdentifier("daily-review-next")
        }
        .font(.body.weight(.semibold))
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private func card<Content: View>(eyebrow: String, title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        let cardContent = content()
        return GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text(eyebrow.uppercased()).font(.caption.weight(.bold)).tracking(1.5)
                        Spacer()
                        Image(systemName: symbol).font(.largeTitle)
                    }
                    .foregroundStyle(accent)
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    cardContent
                }
                .padding(28)
                .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 8), alignment: .topLeading)
            }
            .background {
                RoundedRectangle(cornerRadius: 28)
                    .fill(OTodoTheme.card)
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [accent.opacity(0.13), kind == .morning ? OTodoTheme.gold.opacity(0.08) : OTodoTheme.violet.opacity(0.05), .clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                    }
            }
            .overlay { RoundedRectangle(cornerRadius: 28).stroke(accent.opacity(0.14), lineWidth: 1) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func opening(_ summary: DailyReviewSummary) -> some View {
        card(
            eyebrow: kind == .morning ? "A fresh beginning" : "Set the day down",
            title: kind == .morning ? "Your day. Your pace." : "A little space to reflect.",
            symbol: kind.symbol
        ) {
            Text(kind.invitation).font(.title3).foregroundStyle(.secondary)
            summaryNumbers(summary)
            Text(summary.dueToday.isEmpty && summary.overdue.isEmpty
                ? "Nothing dated needs your attention for this day. Leave room for what matters beyond your list."
                : "One card at a time: finish what’s done, give something a new date, or say LFG and keep its state exactly as it is.")
                .font(.body)
            affirmation()
        }
        .accessibilityIdentifier("daily-review-opening")
    }

    @ViewBuilder
    private func taskCard(_ reference: DailyReviewSession.TaskReference) -> some View {
        if let task = model.tasks.first(where: { $0.id == reference.id }) {
            card(eyebrow: task.dueDate.map { $0.rawValue < session.day ? "Carried forward" : "On your radar" } ?? "Your todo", title: task.name, symbol: "checkmark.circle") {
                if !task.projectSlugs.isEmpty {
                    Label(task.projectSlugs.joined(separator: " · "), systemImage: "folder")
                        .foregroundStyle(.secondary)
                }
                if let due = task.dueDate {
                    Label("Due \(due.rawValue)\(task.dueTime.map { " at \($0.rawValue)" } ?? "")", systemImage: "calendar")
                        .font(.headline)
                }
                if let resolution = session.resolutions[task.id.rawValue] {
                    Label(resolution == .completed ? "Completion saved. Nicely done." : "New schedule saved. Space made.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(accent)
                } else if terminalStates.contains(task.state) {
                    Label("This todo is already finished.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(accent)
                } else if !reference.matchesOccurrence(task) {
                    Label("This occurrence changed since you started. Its current details are shown above; replay the review to act on the updated occurrence.", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                } else {
                    Text(kind == .morning ? "Is this the next right thing?" : "Done, or better on another day?")
                        .font(.title3).foregroundStyle(.secondary)
                    if task.recurrence != nil {
                        Text("Done completes this occurrence and keeps the recurring series going.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !model.hierarchy.children(of: task.id).isEmpty {
                        Text("Completion follows this workspace’s subtask rules. Any unfinished-child issue will be shown here.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Button { complete(reference) } label: {
                        Label(task.recurrence == nil ? "Done" : "Done · this occurrence", systemImage: "checkmark")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(OTodoTheme.filledAccent)
                    .disabled(model.isBusy || isSaving || terminalStates.isEmpty)
                    .accessibilityIdentifier("daily-review-complete")
                    Button { reschedule = RescheduleRequest(task: task) } label: {
                        Label("Reschedule", systemImage: "calendar.badge.clock")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy || isSaving)
                    .accessibilityIdentifier("daily-review-reschedule")
                }
                affirmation()
            }
            .accessibilityIdentifier("daily-review-task-\(task.id.rawValue)")
        } else {
            card(eyebrow: "Something changed", title: "This todo has moved on.", symbol: "arrow.triangle.2.circlepath") {
                Text("It is no longer in this workspace. Your place in the review is safe; continue without changing anything.")
                    .foregroundStyle(.secondary)
                affirmation()
            }
        }
    }

    private func reflection(_ summary: DailyReviewSummary) -> some View {
        card(eyebrow: "Notice the good", title: summary.completedOccurrences == 0 ? "Progress isn’t only checkmarks." : "Make your wins visible.", symbol: "sparkles") {
            Text("\(summary.completedOccurrences) recorded completion\(summary.completedOccurrences == 1 ? "" : "s") on this day")
                .font(.title2.weight(.semibold))
            if summary.completedTasks.isEmpty {
                Text("No completions are recorded for this day yet. Preparing, resting, and choosing what not to do matter too.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.completedTasks, id: \.id) { task in
                    Label(task.name, systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(accent)
                }
            }
            Text("Based on completion history in your current workspace, including recurring occurrences. Older todos without recorded history are not counted.")
                .font(.caption).foregroundStyle(.secondary)
            affirmation()
        }
        .accessibilityIdentifier("daily-review-reflection")
    }

    private func closing(_ summary: DailyReviewSummary) -> some View {
        let remaining = summary.dueToday.count + summary.overdue.count
        return card(eyebrow: kind == .morning ? "Take this with you" : "Enough for today", title: kind == .morning ? "Choose one thing. Begin." : "You can put it down now.", symbol: kind == .morning ? "sun.max.fill" : "moon.fill") {
            summaryNumbers(summary)
            Text(remaining == 0
                ? "There is nothing left due for this day. You don’t need to fill the space."
                : "\(remaining) dated todo\(remaining == 1 ? " remains" : "s remain"). A review is a moment of clarity, not a promise to finish everything.")
                .foregroundStyle(.secondary)
            Text("This summary stays current as your todos change. LFG finishes the review, not your remaining todos.")
                .font(.callout).foregroundStyle(.secondary)
            Button {
                if store.finish(session, kind: kind, workspace: workspace) {
                    didFinish = true
                    dismiss()
                }
            } label: {
                Label(kind == .morning ? "LFG · Start my day" : "LFG · Rest easy", systemImage: kind.symbol)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(OTodoTheme.filledAccent)
            .disabled(isSaving)
            .accessibilityIdentifier("daily-review-finish")
            .accessibilityHint("Marks this review as reviewed for this day. Does not change any todos.")
        }
        .accessibilityIdentifier("daily-review-closing")
    }

    private func summaryNumbers(_ summary: DailyReviewSummary) -> some View {
        VStack(spacing: 14) {
            summaryRow("Due this day", count: summary.dueToday.count, symbol: "sun.max")
            summaryRow("Carried from earlier", count: summary.overdue.count, symbol: "arrow.turn.down.right")
            summaryRow("Recorded completions", count: summary.completedOccurrences, symbol: "checkmark.circle")
        }
        .padding(18)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
    }

    private func summaryRow(_ title: String, count: Int, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: symbol).font(.body)
            Spacer()
            Text(count.formatted()).font(.title2.weight(.bold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func affirmation() -> some View {
        Button { move(by: 1) } label: {
            Label("LFG", systemImage: "arrow.right")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .disabled(isSaving)
        .accessibilityIdentifier("daily-review-lfg")
        .accessibilityHint("Continue to the next card without changing any todo.")
    }

    private func move(by offset: Int) {
        actionError = nil
        let page = max(0, min(session.page + offset, session.pageCount - 1))
        if reduceMotion { session.page = page }
        else { withAnimation(.easeInOut(duration: 0.2)) { session.page = page } }
    }

    private func persist() {
        // Finishing removes the resumable session. Dismissal must not recreate it.
        guard !didFinish else { return }
        store.saveSession(session, kind: kind, workspace: workspace)
    }

    private func complete(_ reference: DailyReviewSession.TaskReference) {
        guard !isSaving, !model.isBusy, model.workspaceSelection == request.selection,
              let task = model.tasks.first(where: { $0.id == reference.id }),
              !terminalStates.contains(task.state), reference.matchesOccurrence(task),
              session.resolutions[task.id.rawValue] == nil else { return }
        isSaving = true
        actionError = nil
        Task { @MainActor in
            await model.completeTask(task)
            isSaving = false
            guard model.workspaceSelection == request.selection else { return }
            if let message = model.errorMessage { actionError = message; return }
            guard let updated = model.tasks.first(where: { $0.id == task.id }),
                  !reference.matchesOccurrence(updated) || terminalStates.contains(updated.state) else {
                actionError = "Completion could not be confirmed. Refresh your workspace before trying again."
                return
            }
            session.resolutions[task.id.rawValue] = .completed
            if store.saveSession(session, kind: kind, workspace: workspace) { move(by: 1) }
        }
    }

    private func saveSchedule(_ task: TodoTask, dueDate: TaskDueDateChange, dueTime: TaskDueTimeChange) async -> String? {
        guard !isSaving, !model.isBusy else { return "Another save is in progress. Try again when it finishes." }
        guard model.workspaceSelection == request.selection else { return "The workspace changed. Reopen your review." }
        guard model.tasks.first(where: { $0.id == task.id }) == task else {
            return "This todo changed while the schedule was open. Cancel and reopen Reschedule to use its current details."
        }
        isSaving = true
        defer { isSaving = false }
        await model.rescheduleTasks([task], dueDate: dueDate, dueTime: dueTime)
        guard model.workspaceSelection == request.selection else { return "The workspace changed. Reopen your review." }
        if let message = model.errorMessage { return message }
        session.resolutions[task.id.rawValue] = .rescheduled
        guard store.saveSession(session, kind: kind, workspace: workspace) else { return store.errorMessage }
        move(by: 1)
        return nil
    }
}
