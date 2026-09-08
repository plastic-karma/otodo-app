import OTodoCore
import SwiftUI
import UIKit

struct ReminderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let notifications: TaskNotificationManager
    private let tasks: [TodoTask]
    private let states: [WorkflowState]
    @State private var timing: Timing
    @State private var customValue: String

    private enum Timing: String, CaseIterable, Identifiable {
        case atDueTime = "At due time"
        case fiveMinutes = "5 minutes before"
        case oneHour = "1 hour before"
        case customHours = "Custom hours before"
        case customDays = "Custom days before"

        var id: String { rawValue }
        var isCustom: Bool { self == .customHours || self == .customDays }
    }

    init(notifications: TaskNotificationManager, tasks: [TodoTask], states: [WorkflowState]) {
        self.notifications = notifications
        self.tasks = tasks
        self.states = states
        let preference = notifications.leadTime
        let timing: Timing
        if preference == .atDueTime {
            timing = .atDueTime
        } else if preference == .fiveMinutes {
            timing = .fiveMinutes
        } else if preference == .oneHour {
            timing = .oneHour
        } else {
            timing = preference.unit == .days ? .customDays : .customHours
        }
        _timing = State(initialValue: timing)
        _customValue = State(initialValue: timing.isCustom ? String(preference.value) : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Due reminders", value: authorizationDescription)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("reminder-authorization-status")
                    if notifications.isEnabled {
                        Button("Disable Reminders", role: .destructive) {
                            Task { await notifications.disable() }
                        }
                        .accessibilityIdentifier("reminder-disable")
                    } else if notifications.status != .denied {
                        Button("Enable Reminders") {
                            Task { await notifications.enable(tasks: tasks, states: states) }
                        }
                        .accessibilityIdentifier("reminder-enable")
                    }
                    Button("Open iOS Notification Settings", systemImage: "arrow.up.right.square") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        Task { _ = await UIApplication.shared.open(url) }
                    }
                    .accessibilityIdentifier("reminder-system-settings")
                } header: {
                    Text("This Device")
                } footer: {
                    Text("These settings apply to all due reminders on this device only. They do not change your todos or Git data. iOS notification settings and Focus can silence alerts.")
                }
                .disabled(notifications.isUpdating || notifications.status == .checking)

                Section {
                    Picker("Remind me", selection: $timing) {
                        ForEach(Timing.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .accessibilityIdentifier("reminder-timing")

                    if timing.isCustom {
                        TextField(timing == .customDays ? "Number of days" : "Number of hours", text: $customValue)
                            .keyboardType(.numberPad)
                            .accessibilityLabel(timing == .customDays ? "Days before" : "Hours before")
                            .accessibilityIdentifier("reminder-custom-value")
                        if selectedLeadTime == nil {
                            Text("Enter a positive whole number. Your saved reminder timing will not change until you apply a valid value.")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("reminder-timing-validation")
                        }
                    }

                    LabeledContent("Saved timing", value: notifications.leadTime.displayName)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("reminder-saved-timing")
                    Button("Apply Timing") {
                        guard let preference = selectedLeadTime else { return }
                        Task {
                            await notifications.setLeadTime(preference, tasks: tasks, states: states)
                        }
                    }
                    .disabled(selectedLeadTime == nil || selectedLeadTime == notifications.leadTime)
                    .accessibilityIdentifier("reminder-apply-timing")
                } header: {
                    Text("Reminder Timing")
                } footer: {
                    Text("At due time uses a todo’s exact time, or 9:00 AM when only a date is set. Days keep the local clock time across daylight-saving changes; hours are elapsed time. If the reminder time has already passed, an undelivered reminder is scheduled shortly. Already delivered occurrences are not repeated when timing changes.")
                }
                .disabled(notifications.isUpdating)

                if notifications.isUpdating {
                    ProgressView("Updating reminders…")
                        .accessibilityIdentifier("reminder-updating")
                }
                if let error = notifications.errorMessage {
                    Section("Could Not Update Reminders") {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("reminder-error")
                        Button("Retry Scheduling") {
                            Task { await notifications.synchronize(tasks: tasks, states: states) }
                        }
                        .disabled(notifications.isUpdating)
                    }
                }
            }
            .navigationTitle("Due Reminders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("reminder-settings-done")
                }
            }
            .task { await notifications.synchronize(tasks: tasks, states: states) }
        }
    }

    private var selectedLeadTime: TaskReminderLeadTime? {
        switch timing {
        case .atDueTime: return .atDueTime
        case .fiveMinutes: return .fiveMinutes
        case .oneHour: return .oneHour
        case .customHours, .customDays:
            let value = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  value.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                  let count = Int(value)
            else { return nil }
            return TaskReminderLeadTime(value: count, unit: timing == .customDays ? .days : .hours)
        }
    }

    private var authorizationDescription: String {
        switch notifications.status {
        case .checking: "Checking notification access"
        case .notRequested: "Permission not requested"
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .denied: "Denied in iOS Settings"
        }
    }
}

extension TaskReminderLeadTime {
    var displayName: String {
        if self == .atDueTime { return "At due time (date-only: 9:00 AM)" }
        switch unit {
        case .minutes: return "\(value) \(value == 1 ? "minute" : "minutes") before"
        case .hours: return "\(value) \(value == 1 ? "hour" : "hours") before"
        case .days: return "\(value) \(value == 1 ? "calendar day" : "calendar days") before"
        }
    }
}
