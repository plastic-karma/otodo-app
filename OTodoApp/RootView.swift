import SwiftUI

struct RootView: View {
    @Bindable private var model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        Group {
            switch model.rootState {
            case .missingOAuthConfiguration:
                ContentUnavailableView {
                    Label("GitHub OAuth is not configured", systemImage: "key.slash")
                } description: {
                    Text("Set the GITHUB_CLIENT_ID build setting to the client ID of a GitHub OAuth app, then rebuild OTodo.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OTodoCanvas())
            case .authentication:
                AuthenticationView(model: model)
            case .onboarding:
                RepositorySetupView(model: model)
            case .workspace:
                TaskListView(model: model)
            }
        }
    }
}
