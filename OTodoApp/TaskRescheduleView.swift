import Foundation
import OTodoCore
import SwiftUI

struct TaskRescheduleView: View {
    @Environment(\.dismiss) private var dismiss

    private typealias Change = TaskSchedule.FieldChange

    private let tasks: [TodoTask]
    private let onSave: @MainActor (TaskDueDateChange, TaskDueTimeChange) async -> String?

    @State private var selectedDate: Date
    @State private var selectedTime: Date
    @State private var dateChange: Change
    @State private var timeChange: Change
    @State private var hasPendingRelativeDueDate = false
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        tasks: [TodoTask],
        onSave: @escaping @MainActor (TaskDueDateChange, TaskDueTimeChange) async -> String?
    ) {
        self.tasks = tasks
        self.onSave = onSave
        let initialDate = TaskSchedule.date(from: tasks.first?.dueDate, time: tasks.first?.dueTime)
        _selectedDate = State(initialValue: initialDate)
        _selectedTime = State(initialValue: initialDate)
        _dateChange = State(initialValue: tasks.count > 1 ? .preserve : .set)
        _timeChange = State(initialValue: tasks.count > 1 ? .preserve : tasks.first?.dueTime == nil ? .clear : .set)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(isBulk ? "Selected todos" : "Todo") {
                    Label {
                        if isBulk {
                            Text("\(tasks.count) todos")
                        } else {
                            Text(tasks.first?.name ?? String(localized: "No todos selected"))
                        }
                    } icon: {
                        Image(systemName: isBulk ? "calendar.badge.clock" : "calendar")
                    }
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    if isBulk {
                        Text("Only the schedule fields you change will be replaced. Other task details stay intact.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Date and time") {
                    TaskScheduleFields(
                        date: $selectedDate,
                        time: $selectedTime,
                        dateChange: $dateChange,
                        timeChange: $timeChange,
                        hasPendingRelativeDueDate: $hasPendingRelativeDueDate,
                        isBulk: isBulk,
                        identifierPrefix: "task-reschedule",
                        dateIdentifierPrefix: "task-reschedule",
                        helpText: scheduleExplanation,
                        onRelativeApply: { saveError = nil },
                        onQuickChoice: save
                    )
                }

                if let message = validationMessage ?? saveError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Cannot save. \(message)")
                    }
                }
            }
            .disabled(isSaving)
            .accessibilityIdentifier("task-reschedule")
            .scrollContentBackground(.hidden)
            .background(OTodoTheme.formCanvas.ignoresSafeArea())
            .navigationTitle(isBulk ? Text("Reschedule \(tasks.count) todos") : Text("Reschedule"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(OTodoTheme.formCanvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .accessibilityIdentifier("task-reschedule-save")
                    .disabled(
                        validationMessage != nil
                            || hasPendingRelativeDueDate
                            || isSaving
                            || (dateChange == .preserve && timeChange == .preserve)
                    )
                }
            }
            .overlay {
                if isSaving {
                    ProgressView("Saving")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var isBulk: Bool { tasks.count > 1 }

    private var scheduleExplanation: LocalizedStringResource {
        if dateChange == .clear {
            return "Removing dates also removes their times. Recurring todos require a due date."
        }
        if isBulk {
            return "Days, weeks, months, and years change only dates. Hours or minutes set both date and time. Kept times remain different when your todos have different times."
        }
        return timeChange == .set
            ? "This is the todo's exact due time. Notifications follow your Due reminders settings."
            : "Date-only reminders are based on 9:00 AM, with the lead time from Due reminders settings."
    }

    private var validationMessage: String? {
        if tasks.isEmpty {
            return "Select at least one todo."
        }
        if dateChange == .clear && tasks.contains(where: { $0.recurrence != nil }) {
            return "Recurring todos require a due date."
        }
        if dateChange == .set && TaskSchedule.civilDate(from: selectedDate) == nil {
            return "Choose a valid due date."
        }
        if timeChange == .set && dateChange != .clear {
            if TaskSchedule.civilTime(from: selectedTime) == nil {
                return "Choose a valid due time."
            }
            if dateChange == .preserve && tasks.contains(where: { $0.dueDate == nil }) {
                return "Set a date before adding a time to undated todos."
            }
        }
        return nil
    }

    private func save() {
        guard !isSaving, !hasPendingRelativeDueDate, validationMessage == nil else { return }
        let dueDate: TaskDueDateChange
        switch dateChange {
        case .preserve: dueDate = .preserve
        case .clear: dueDate = .clear
        case .set:
            guard let date = TaskSchedule.civilDate(from: selectedDate) else { return }
            dueDate = .set(date)
        }
        let dueTime: TaskDueTimeChange
        switch dateChange == .clear ? .clear : timeChange {
        case .preserve: dueTime = .preserve
        case .clear: dueTime = .clear
        case .set:
            guard let time = TaskSchedule.civilTime(from: selectedTime) else { return }
            dueTime = .set(time)
        }

        isSaving = true
        saveError = nil
        Task { @MainActor in
            let errorMessage = await onSave(dueDate, dueTime)
            isSaving = false
            if let errorMessage {
                saveError = errorMessage
            } else {
                dismiss()
            }
        }
    }
}
