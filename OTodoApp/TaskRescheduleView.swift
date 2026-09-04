import Foundation
import OTodoCore
import SwiftUI

struct TaskRescheduleView: View {
    @Environment(\.dismiss) private var dismiss

    private let task: TodoTask
    private let onSave: @MainActor (CivilDate, CivilTime?) async -> String?

    @State private var selectedDate: Date
    @State private var includesTime: Bool
    @State private var hasPendingRelativeDueDate = false
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        task: TodoTask,
        onSave: @escaping @MainActor (CivilDate, CivilTime?) async -> String?
    ) {
        self.task = task
        self.onSave = onSave
        _selectedDate = State(
            initialValue: TaskSchedule.date(from: task.dueDate, time: task.dueTime)
        )
        _includesTime = State(initialValue: task.dueTime != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Todo") {
                    Label(task.name, systemImage: "checkmark.circle")
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                }

                Section {
                    RelativeDueDateField(
                        accessibilityIdentifierPrefix: "task-reschedule-relative-due",
                        onPendingChange: { hasPendingRelativeDueDate = $0 },
                        onApply: { resolvedDate in
                            selectedDate = resolvedDate
                            includesTime = true
                            saveError = nil
                        }
                    )
                } header: {
                    Text("Relative")
                }

                Section {
                    DatePicker(
                        "Date",
                        selection: $selectedDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .environment(\.calendar, TaskSchedule.calendar)
                    .accessibilityIdentifier("task-reschedule-date-picker")

                    Toggle("Include time", isOn: $includesTime)
                        .accessibilityIdentifier("task-reschedule-time-toggle")

                    if includesTime {
                        DatePicker(
                            "Time",
                            selection: $selectedDate,
                            displayedComponents: .hourAndMinute
                        )
                        .environment(\.calendar, TaskSchedule.calendar)
                        .accessibilityIdentifier("task-reschedule-time-picker")
                    }
                } header: {
                    Text("Date and time")
                } footer: {
                    Text(
                        includesTime
                            ? "The todo and its reminder use this exact time."
                            : "Date-only reminders arrive at 9:00 AM."
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
            .accessibilityIdentifier("task-reschedule")
            .scrollContentBackground(.hidden)
            .background(OTodoCanvas())
            .navigationTitle("Reschedule")
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

    private var validationMessage: String? {
        TaskSchedule.civilDate(from: selectedDate) == nil
            ? "Choose a valid due date."
            : nil
    }

    private func save() {
        guard !hasPendingRelativeDueDate,
              let dueDate = TaskSchedule.civilDate(from: selectedDate)
        else {
            return
        }
        let dueTime = includesTime ? TaskSchedule.civilTime(from: selectedDate) : nil

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
