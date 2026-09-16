import SwiftUI

struct RootView: View {
    @Bindable private var model: AppModel
    private let notifications: TaskNotificationManager

    init(model: AppModel, notifications: TaskNotificationManager) {
        self.model = model
        self.notifications = notifications
    }

    var body: some View {
        Group {
            switch model.rootState {
            case .missingOAuthConfiguration, .authentication:
                AuthenticationView(model: model)
            case .onboarding:
                RepositorySetupView(model: model)
            case .workspace:
                TaskListView(model: model, notifications: notifications)
            }
        }
    }
}
