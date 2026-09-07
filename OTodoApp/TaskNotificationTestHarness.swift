#if DEBUG
import Foundation
import OTodoCore
import SwiftUI
import UserNotifications

/// Supplies the same value snapshot as the OS callbacks, without notification
/// permissions or private UNNotificationResponse construction in simulator tests.
@MainActor
enum TaskNotificationTestHarness {
    private static var didEnterBackground = false

    static func deliverLaunchResponse(to notifications: TaskNotificationManager) {
        guard !ProcessInfo.processInfo.arguments.contains("-ui-testing-notification-on-activation") else { return }
        deliverResponse(to: notifications)
    }

    static func scenePhaseDidChange(_ phase: ScenePhase, notifications: TaskNotificationManager) {
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing-notification-on-activation") else { return }
        if phase == .background {
            didEnterBackground = true
        } else if phase == .active, didEnterBackground {
            didEnterBackground = false
            deliverResponse(to: notifications)
        }
    }

    private static func deliverResponse(to notifications: TaskNotificationManager) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"),
              let flag = arguments.firstIndex(of: "-ui-testing-notification-task"),
              arguments.indices.contains(flag + 1)
        else { return }
        let taskID = arguments[flag + 1]
        notifications.handle(TaskNotificationResponse(
            requestIdentifier: TaskReminderPlanner.identifierPrefix + taskID + ".ui-testing",
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            taskID: taskID,
            deliveredAt: .now
        ))
    }
}
#endif
