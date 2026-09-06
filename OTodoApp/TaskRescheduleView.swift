import Foundation
import OTodoCore
import SwiftUI

struct TaskRescheduleView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Change: Hashable {
        case preserve
        case set
        case clear
    }

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
                    Label(
                        isBulk ? "\(tasks.count) todos" : tasks.first?.name ?? "No todos selected",
                        systemImage: isBulk ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    if isBulk {
                        Text("Only the schedule fields you change will be replaced. Other task details stay intact.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    RelativeDueDateField(
                        accessibilityIdentifierPrefix: "task-reschedule-relative-due",
                        onPendingChange: { hasPendingRelativeDueDate = $0 },
                        onApply: { resolvedDate, unit in
                            selectedDate = resolvedDate
                            dateChange = .set
                            if !isBulk || unit == .minute || unit == .hour {
                                selectedTime = resolvedDate
                                timeChange = .set
                            }
                            saveError = nil
                        }
                    )
                } header: {
                    Text("Relative")
                }

                Section {
                    if isBulk {
                        Picker("Due dates", selection: $dateChange) {
                            Text("Keep existing dates").tag(Change.preserve)
                            Text("Set date").tag(Change.set)
                            Text("Remove dates").tag(Change.clear)
                        }
                        .accessibilityIdentifier("task-reschedule-date-change")
                    }

                    if dateChange == .set {
                        DatePicker(
                            "Date",
                            selection: $selectedDate,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                        .environment(\.calendar, TaskSchedule.calendar)
                        .accessibilityIdentifier("task-reschedule-date-picker")
                    }

                    if dateChange != .clear {
                        if isBulk {
                            Picker("Due times", selection: $timeChange) {
                                Text("Keep existing times").tag(Change.preserve)
                                Text("Set time").tag(Change.set)
                                Text("Remove times").tag(Change.clear)
                            }
                            .accessibilityIdentifier("task-reschedule-time-change")
                        } else {
                            Toggle("Include time", isOn: Binding(
                                get: { timeChange == .set },
                                set: { timeChange = $0 ? .set : .clear }
                            ))
                            .accessibilityIdentifier("task-reschedule-time-toggle")
                        }

                        if timeChange == .set {
                            DatePicker(
                                "Time",
                                selection: $selectedTime,
                                displayedComponents: .hourAndMinute
                            )
                            .environment(\.calendar, TaskSchedule.calendar)
                            .accessibilityIdentifier("task-reschedule-time-picker")
                        }
                    }
                } header: {
                    Text("Date and time")
                } footer: {
                    Text(scheduleExplanation)
                }

                if let message = validationMessage ?? saveError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Cannot save. \(message)")
                    }
                }
            }
            .accessibilityIdentifier("task-reschedule")
            .scrollContentBackground(.hidden)
            .background(OTodoCanvas())
            .navigationTitle(isBulk ? "Reschedule \(tasks.count) todos" : "Reschedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
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

    private var scheduleExplanation: String {
        if dateChange == .clear {
            return "Removing dates also removes their times. Recurring todos require a due date."
        }
        if isBulk {
            return "Days, weeks, months, and years change only dates. Hours or minutes set both date and time. Kept times remain different when your todos have different times."
        }
        return timeChange == .set
            ? "The todo and its reminder use this exact time."
            : "Date-only reminders arrive at 9:00 AM."
    }

    private var validationMessage: String? {
        if tasks.isEmpty {
            return "Select at least one todo."
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
        guard !hasPendingRelativeDueDate, validationMessage == nil else { return }
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
