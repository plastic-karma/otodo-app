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

    private(set) var status: Status = .checking
    private(set) var isUpdating = false
    private(set) var errorMessage: String?
    private(set) var pendingTaskID: TaskID?

    @ObservationIgnored private var lastResponse: TaskNotificationResponse?

    @ObservationIgnored private let center: UNUserNotificationCenter
    @ObservationIgnored private let defaults: UserDefaults

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
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
        errorMessage = nil
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            status = .notRequested
            if !remindersEnabledPreference {
                await clearTaskReminders()
            }
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

    func enable(tasks: [TodoTask], states: [WorkflowState]) async {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        defer { isUpdating = false }

        do {
            let settings = await center.notificationSettings()
            let isAuthorized: Bool
            switch settings.authorizationStatus {
            case .notDetermined:
                isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
            case .authorized, .provisional, .ephemeral:
                isAuthorized = true
            case .denied:
                isAuthorized = false
            @unknown default:
                isAuthorized = false
            }

            defaults.set(true, forKey: Self.enabledDefaultsKey)
            guard isAuthorized else {
                status = .denied
                return
            }

            status = .enabled
            await replaceTaskReminders(tasks: tasks, states: states)
        } catch {
            defaults.set(false, forKey: Self.enabledDefaultsKey)
            status = .notRequested
            errorMessage = error.localizedDescription
        }
    }

    func disable() async {
        defaults.set(false, forKey: Self.enabledDefaultsKey)
        errorMessage = nil
        status = .disabled
        await clearTaskReminders()
    }

    private var remindersEnabledPreference: Bool {
        defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    private func replaceTaskReminders(tasks: [TodoTask], states: [WorkflowState]) async {
        let calendar = Self.localGregorianCalendar
        let reminders = TaskReminderPlanner.reminders(
            for: tasks,
            states: states,
            calendar: calendar
        )
        let desiredIdentifiers = Set(reminders.map(\.identifier))
        let pending = await center.pendingNotificationRequests()
        let pendingIdentifiers = pending.lazy
            .map(\.identifier)
            .filter { $0.hasPrefix(TaskReminderPlanner.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: Array(pendingIdentifiers))

        let delivered = await center.deliveredNotifications()
        let deliveredIdentifiers = Set(
            delivered.lazy
                .map { $0.request.identifier }
                .filter { $0.hasPrefix(TaskReminderPlanner.identifierPrefix) }
        )
        let staleDeliveredIdentifiers = deliveredIdentifiers.subtracting(desiredIdentifiers)
        if !staleDeliveredIdentifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: Array(staleDeliveredIdentifiers))
        }

        for reminder in reminders where !deliveredIdentifiers.contains(reminder.identifier) {
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

            do {
                try await center.add(request)
            } catch {
                errorMessage = error.localizedDescription
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

    private static var localGregorianCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
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
