import Foundation
import OTodoCore
import UserNotifications
import XCTest
@testable import OTodo

@MainActor
final class TaskNotificationRoutingTests: XCTestCase {
    private let targetID = "01ARZ3NDEKTSV4RRFFQ69G5FAX"

    func testColdResponseWaitsForConsumerAndIsConsumedOnce() throws {
        let notifications = TaskNotificationManager()
        notifications.handle(response())

        // No workspace/view exists yet. The request survives until one consumes it.
        XCTAssertEqual(notifications.pendingTaskID, try TaskID(rawValue: targetID))
        XCTAssertEqual(notifications.consumePendingTaskRequest(), try TaskID(rawValue: targetID))
        XCTAssertNil(notifications.consumePendingTaskRequest())
    }

    func testDuplicateSceneAndCenterDeliveryDoesNotReopenConsumedTask() throws {
        let notifications = TaskNotificationManager()
        let tap = response()
        notifications.handle(tap)
        XCTAssertEqual(notifications.consumePendingTaskRequest(), try TaskID(rawValue: targetID))

        notifications.handle(tap)
        XCTAssertNil(notifications.consumePendingTaskRequest())

        // A later delivery of a reminder for this task must still open it.
        notifications.handle(response(deliveredAt: tap.deliveredAt.addingTimeInterval(60)))
        XCTAssertEqual(notifications.consumePendingTaskRequest(), try TaskID(rawValue: targetID))
    }

    func testDismissUnknownPayloadAndInvalidIDsDoNotReplacePendingTap() throws {
        let notifications = TaskNotificationManager()
        notifications.handle(response())
        let ignored = [
            response(action: UNNotificationDismissActionIdentifier),
            response(action: "unsupported-action"),
            response(identifier: "unrelated-notification"),
            response(taskID: "not-a-task"),
            response(taskID: nil),
        ]
        for tap in ignored {
            notifications.handle(tap)
        }
        XCTAssertEqual(notifications.consumePendingTaskRequest(), try TaskID(rawValue: targetID))
        for tap in ignored {
            notifications.handle(tap)
        }
        XCTAssertNil(notifications.pendingTaskID)
    }

    func testLatestValidTapWinsWhilePresentationIsUnavailable() throws {
        let notifications = TaskNotificationManager()
        notifications.handle(response())
        let nextID = "01ARZ3NDEKTSV4RRFFQ69G5FAY"
        notifications.handle(response(taskID: nextID))
        XCTAssertEqual(notifications.consumePendingTaskRequest(), try TaskID(rawValue: nextID))
    }

    private func response(
        identifier: String = "otodo.task.reminder",
        action: String = UNNotificationDefaultActionIdentifier,
        taskID: String? = "01ARZ3NDEKTSV4RRFFQ69G5FAX",
        deliveredAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> TaskNotificationResponse {
        TaskNotificationResponse(
            requestIdentifier: identifier,
            actionIdentifier: action,
            taskID: taskID,
            deliveredAt: deliveredAt
        )
    }
}
