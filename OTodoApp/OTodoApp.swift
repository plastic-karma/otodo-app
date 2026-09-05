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
#if DEBUG
                .preferredColorScheme(testColorScheme)
#endif
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
#if DEBUG
    private var testColorScheme: ColorScheme? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing") else { return nil }
        if arguments.contains("-ui-testing-dark") { return .dark }
        if arguments.contains("-ui-testing-light") { return .light }
        return nil
    }
#endif


    private func synchronizeSystemSurfaces() async {
        let states = model.configuration?.states ?? []
        TodayWidgetCoordinator.synchronize(tasks: model.tasks, states: states)
        await notifications.synchronize(tasks: model.tasks, states: states)
    }
}
