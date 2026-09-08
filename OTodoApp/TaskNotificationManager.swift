import Foundation
import Observation
import OTodoCore
import UserNotifications

@MainActor
@Observable
final class TaskNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    enum Status: Equatable {
        case checking
        case notRequested
        case enabled
        case disabled
        case denied
    }

    private static let enabledDefaultsKey = "notifications.reminders-enabled"
    private static let leadTimeDefaultsKey = "notifications.reminder-lead-time"

    private(set) var status: Status = .checking
    private(set) var isUpdating = false
    private(set) var errorMessage: String?
    private(set) var pendingTaskID: TaskID?
    private(set) var leadTime: TaskReminderLeadTime

    @ObservationIgnored private var lastResponse: TaskNotificationResponse?

    @ObservationIgnored private let center: UNUserNotificationCenter
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var synchronizationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSynchronizations = 0

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
        if let stored = defaults.dictionary(forKey: Self.leadTimeDefaultsKey),
           let value = stored["value"] as? Int,
           let rawUnit = stored["unit"] as? String,
           let unit = TaskReminderLeadTime.Unit(rawValue: rawUnit),
           let preference = TaskReminderLeadTime(value: value, unit: unit) {
            leadTime = preference
        } else {
            leadTime = .atDueTime
        }
        super.init()
    }

    var isEnabled: Bool {
        status == .enabled
    }

    /// Install before application launch finishes so a cold-start tap is retained.
    func registerResponseDelegate() {
        center.delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard notification.request.identifier.hasPrefix(TaskReminderPlanner.identifierPrefix) else {
            return []
        }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // UNNotificationResponse stays on its delivery executor. Only this Sendable
        // snapshot crosses to the main actor; returning completes the OS callback.
        let snapshot = TaskNotificationResponse(response)
        await handle(snapshot)
    }

    func handle(_ response: TaskNotificationResponse) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              response.requestIdentifier.hasPrefix(TaskReminderPlanner.identifierPrefix),
              let rawTaskID = response.taskID,
              let taskID = try? TaskID(rawValue: rawTaskID),
              response != lastResponse
        else { return }

        // Scene connection and the notification delegate can deliver the same tap.
        // Remember it after consumption too, without blocking a later reminder.
        lastResponse = response
        pendingTaskID = taskID
    }

    func consumePendingTaskRequest() -> TaskID? {
        defer { pendingTaskID = nil }
        return pendingTaskID
    }

    func synchronize(tasks: [TodoTask], states: [WorkflowState]) async {
        await enqueueSynchronization(tasks: tasks, states: states)
    }

    func enable(tasks: [TodoTask], states: [WorkflowState]) async {
        guard !isUpdating else { return }
        defaults.set(true, forKey: Self.enabledDefaultsKey)
        await enqueueSynchronization(tasks: tasks, states: states, requestAuthorization: true)
    }

    func disable() async {
        defaults.set(false, forKey: Self.enabledDefaultsKey)
        await enqueueSynchronization(tasks: [], states: [])
    }

    func setLeadTime(
        _ preference: TaskReminderLeadTime,
        tasks: [TodoTask],
        states: [WorkflowState]
    ) async {
        leadTime = preference
        if preference == .atDueTime {
            defaults.removeObject(forKey: Self.leadTimeDefaultsKey)
        } else {
            defaults.set(
                ["value": preference.value, "unit": preference.unit.rawValue],
                forKey: Self.leadTimeDefaultsKey
            )
        }
        await enqueueSynchronization(tasks: tasks, states: states)
    }

    private func enqueueSynchronization(
        tasks: [TodoTask],
        states: [WorkflowState],
        requestAuthorization: Bool = false
    ) async {
        // Native add/remove operations must not interleave across preference,
        // workspace, and scene changes, or an older request can win the race.
        let previous = synchronizationTask
        pendingSynchronizations += 1
        isUpdating = true
        let operation = Task { @MainActor in
            await previous?.value
            await applySynchronization(
                tasks: tasks, states: states, requestAuthorization: requestAuthorization
            )
        }
        synchronizationTask = operation
        await operation.value
        pendingSynchronizations -= 1
        isUpdating = pendingSynchronizations > 0
        if !isUpdating {
            synchronizationTask = nil
        }
    }

    private func applySynchronization(
        tasks: [TodoTask],
        states: [WorkflowState],
        requestAuthorization: Bool
    ) async {
        errorMessage = nil
        var settings = await center.notificationSettings()
        if requestAuthorization, settings.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            } catch {
                status = .notRequested
                errorMessage = error.localizedDescription
                return
            }
        }
        switch settings.authorizationStatus {
        case .notDetermined:
            status = .notRequested
            await clearTaskReminders()
        case .denied:
            status = .denied
            await clearTaskReminders()
        case .authorized, .provisional, .ephemeral:
            guard remindersEnabledPreference else {
                status = .disabled
                await clearTaskReminders()
                return
            }
            status = .enabled
            await replaceTaskReminders(tasks: tasks, states: states)
        @unknown default:
            status = .denied
            await clearTaskReminders()
        }
    }

    private var remindersEnabledPreference: Bool {
        defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    private func replaceTaskReminders(tasks: [TodoTask], states: [WorkflowState]) async {
        let calendar = TaskSchedule.calendar
        let delivered = await center.deliveredNotifications()
        let deliveredIdentifiers = Set(
            delivered.lazy
                .map { $0.request.identifier }
                .filter { $0.hasPrefix(TaskReminderPlanner.identifierPrefix) }
        )
        let terminalStateIDs = Set(states.lazy.filter(\.isTerminal).map(\.id))
        let activeIdentifiers = Set(tasks.lazy
            .filter { !terminalStateIDs.contains($0.state) }
            .compactMap { TaskReminderPlanner.identifier(for: $0) })
        let staleDeliveredIdentifiers = deliveredIdentifiers.subtracting(activeIdentifiers)
        if !staleDeliveredIdentifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: Array(staleDeliveredIdentifiers))
        }
        let reminders = TaskReminderPlanner.reminders(
            for: tasks,
            states: states,
            calendar: calendar,
            leadTime: leadTime,
            excludingIdentifiers: deliveredIdentifiers
        )
        let desiredIdentifiers = Set(reminders.map(\.identifier))
        let pending = await center.pendingNotificationRequests()
        let stalePendingIdentifiers = pending.lazy
            .map(\.identifier)
            .filter {
                $0.hasPrefix(TaskReminderPlanner.identifierPrefix)
                    && !desiredIdentifiers.contains($0)
            }
        center.removePendingNotificationRequests(withIdentifiers: Array(stalePendingIdentifiers))

        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = notificationTitle(for: reminder.timing)
            content.body = reminder.taskName
            content.sound = .default
            content.threadIdentifier = "otodo.tasks"
            content.userInfo = ["task_id": reminder.taskID.rawValue]

            var components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: reminder.fireDate
            )
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: components,
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: reminder.identifier,
                content: content,
                trigger: trigger
            )

            // Adding the same identifier replaces its trigger atomically, keeping
            // the old pending request if the native scheduler rejects this one.
            do {
                try await center.add(request)
            } catch {
                errorMessage = "Could not schedule “\(reminder.taskName)”: \(error.localizedDescription)"
            }
        }
    }

    private func clearTaskReminders() async {
        let pending = await center.pendingNotificationRequests()
        let pendingIdentifiers = pending.lazy
            .map(\.identifier)
            .filter { $0.hasPrefix(TaskReminderPlanner.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: Array(pendingIdentifiers))

        let delivered = await center.deliveredNotifications()
        let deliveredIdentifiers = delivered.lazy
            .map { $0.request.identifier }
            .filter { $0.hasPrefix(TaskReminderPlanner.identifierPrefix) }
        center.removeDeliveredNotifications(withIdentifiers: Array(deliveredIdentifiers))
    }

    private func notificationTitle(for timing: TaskReminderTiming) -> String {
        switch timing {
        case .overdue:
            "Todo overdue"
        case .dueToday:
            "Todo due today"
        case .upcoming:
            "Upcoming todo"
        }
    }

}

/// Value snapshot shared by scene connection and notification-center delivery.
struct TaskNotificationResponse: Sendable, Equatable {
    let requestIdentifier: String
    let actionIdentifier: String
    let taskID: String?
    let deliveredAt: Date

    init(
        requestIdentifier: String,
        actionIdentifier: String,
        taskID: String?,
        deliveredAt: Date
    ) {
        self.requestIdentifier = requestIdentifier
        self.actionIdentifier = actionIdentifier
        self.taskID = taskID
        self.deliveredAt = deliveredAt
    }

    init(_ response: UNNotificationResponse) {
        let notification = response.notification
        self.init(
            requestIdentifier: notification.request.identifier,
            actionIdentifier: response.actionIdentifier,
            taskID: notification.request.content.userInfo["task_id"] as? String,
            deliveredAt: notification.date
        )
    }
}
