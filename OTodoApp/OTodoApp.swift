import SwiftUI

@main
@MainActor
struct OTodoApp: App {
    @UIApplicationDelegateAdaptor(OTodoApplicationDelegate.self)
    private var applicationDelegate

    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()
    @State private var notifications = TaskNotificationManager()

    var body: some Scene {
        WindowGroup {
            RootView(model: model, notifications: notifications)
                .tint(OTodoTheme.accent)
                .task {
                    await model.start()
                    await synchronizeSystemSurfaces()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { @MainActor in
                        await model.sceneDidBecomeActive()
                        await synchronizeSystemSurfaces()
                    }
                }
                .onChange(of: model.tasks) { _, _ in
                    Task { @MainActor in
                        await synchronizeSystemSurfaces()
                    }
                }
        }
    }

    private func synchronizeSystemSurfaces() async {
        let states = model.configuration?.states ?? []
        TodayWidgetCoordinator.synchronize(tasks: model.tasks, states: states)
        await notifications.synchronize(tasks: model.tasks, states: states)
    }
}
