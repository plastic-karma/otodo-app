import SwiftUI
import OTodoCore

@main
@MainActor
struct OTodoApp: App {
    @UIApplicationDelegateAdaptor(OTodoApplicationDelegate.self)
    private var applicationDelegate

    @Environment(\.scenePhase) private var scenePhase
    @State private var startup: Result<AppModel, Error> = Result { try AppModel() }
    @State private var notifications = TaskNotificationManager()
    @State private var watchSync = PhoneWatchSync()

    var body: some Scene {
        WindowGroup {
            switch startup {
            case let .success(model):
                RootView(model: model, notifications: notifications)
                    .tint(OTodoTheme.accent)
    #if DEBUG
                    .preferredColorScheme(testColorScheme)
    #endif
                    .task {
                        await model.start()
                        await synchronizeSystemSurfaces(model: model)
                    }
                    .onChange(of: scenePhase) { _, phase in
                        guard phase == .active else { return }
                        Task { @MainActor in
                            await model.sceneDidBecomeActive()
                            await synchronizeSystemSurfaces(model: model)
                        }
                    }
                    .onChange(of: model.tasks) { _, _ in
                        Task { @MainActor in
                            await synchronizeSystemSurfaces(model: model)
                        }
                    }
                    .onChange(of: model.configuration) { _, _ in
                        Task { @MainActor in
                            await synchronizeSystemSurfaces(model: model)
                        }
                    }
                    .onChange(of: model.workspaceSelection) { _, _ in
                        Task { @MainActor in
                            await synchronizeSystemSurfaces(model: model)
                        }
                    }
            case let .failure(error):
                ContentUnavailableView {
                    Label("Unable to open workspace", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("Retry") {
                        startup = Result { try AppModel() }
                    }
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


    private func synchronizeSystemSurfaces(model: AppModel) async {
        let workspaceAvailable = model.workspaceSelection != nil
        let tasks = workspaceAvailable ? model.tasks : []
        let states = model.configuration?.states ?? []
        let snapshot = TodayWidgetSnapshotBuilder.make(tasks: tasks, states: states)
        TodayWidgetCoordinator.synchronize(snapshot: snapshot)
        watchSync.synchronize(snapshot: snapshot, workspaceAvailable: workspaceAvailable)
        await notifications.synchronize(tasks: tasks, states: states)
    }
}
