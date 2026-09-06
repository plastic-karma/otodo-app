import SwiftUI
import WatchKit

@main
struct OTodoWatchApp: App {
    @WKApplicationDelegateAdaptor(OTodoWatchDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            WatchTodayView(receiver: .shared)
                .tint(Color(red: 0.70, green: 0.45, blue: 0.94))
        }
    }
}

@MainActor
final class OTodoWatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WatchSnapshotReceiver.shared.start()
    }

    func applicationDidBecomeActive() {
        WatchSnapshotReceiver.shared.refresh()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivityTask = task as? WKWatchConnectivityRefreshBackgroundTask {
                WatchSnapshotReceiver.shared.retainBackgroundTask(connectivityTask)
            } else if let snapshotTask = task as? WKSnapshotRefreshBackgroundTask {
                snapshotTask.setTaskCompleted(
                    restoredDefaultState: false,
                    estimatedSnapshotExpiration: Calendar.current.nextDate(
                        after: .now,
                        matching: DateComponents(hour: 0, minute: 0, second: 0),
                        matchingPolicy: .nextTime
                    ),
                    userInfo: nil
                )
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
