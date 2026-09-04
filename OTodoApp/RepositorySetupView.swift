import OTodoCore
import SwiftUI

struct RepositorySetupView: View {
    @Bindable private var model: AppModel
    @State private var isConfirmingSignOut = false
    @State private var needsStoreRefresh = false

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        NavigationStack {
            List {
                if model.isBusy || model.statusMessage != nil {
                    Section {
                        if model.isBusy {
                            ProgressView(model.statusMessage ?? "Working…")
                                .accessibilityIdentifier("repository.progress")
                        } else if let statusMessage = model.statusMessage {
                            Label(statusMessage, systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("repository.status")
                        }
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Label {
                            Text(errorMessage)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("repository.error")

                        Button("Try Again") {
                            retryCurrentStep()
                        }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("repository.retry")
                    }
                }

                repositorySection

                if model.selectedRepositoryID != nil {
                    branchSection
                    storeSection
                    connectSection
                }
            }
            .scrollContentBackground(.hidden)
            .background(OTodoCanvas())
            .navigationTitle("Choose Todo Store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .refreshable {
                await model.loadRepositories()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign Out") {
                        isConfirmingSignOut = true
                    }
                    .accessibilityIdentifier("repository.signOut")
                }
            }
            .confirmationDialog(
                "Sign out of GitHub?",
                isPresented: $isConfirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    Task {
                        await model.signOut()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will need to authorize OTodo again to access your repositories.")
            }
            .task {
                if model.repositories.isEmpty, !model.isBusy {
                    await model.loadRepositories()
                }
            }
        }
    }

    @ViewBuilder
    private var repositorySection: some View {
        Section {
            if model.repositories.isEmpty {
                if model.isBusy {
                    HStack {
                        Spacer()
                        ProgressView("Loading repositories…")
                        Spacer()
                    }
                    .accessibilityIdentifier("repository.loading")
                } else if model.errorMessage == nil {
                    ContentUnavailableView {
                        Label("No repositories", systemImage: "shippingbox")
                    } description: {
                        Text("No GitHub repositories are available to this account.")
                    } actions: {
                        Button("Reload") {
                            Task {
                                await model.loadRepositories()
                            }
                        }
                        .accessibilityIdentifier("repository.reload")
                    }
                    .accessibilityIdentifier("repository.empty")
                }
            } else {
                ForEach(model.repositories, id: \.stableID) { repository in
                    repositoryButton(repository)
                }
            }
        } header: {
            Text("Repository")
        } footer: {
            Text("Private repositories are accessed only after you approve GitHub’s repository permission.")
        }
    }

    private func repositoryButton(_ repository: RepositorySummary) -> some View {
        let isSelected = model.selectedRepositoryID == repository.stableID

        return Button {
            selectRepository(repository.stableID)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(repository.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(repository.owner)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Label(
                    repository.isPrivate ? "Private" : "Public",
                    systemImage: repository.isPrivate ? "lock.fill" : "globe"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected ? OTodoTheme.accent.opacity(0.10) : OTodoTheme.raisedCard
        )
        .disabled(model.isBusy)
        .accessibilityLabel("\(repository.owner) slash \(repository.name), \(repository.isPrivate ? "Private" : "Public") repository")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Selects this repository and searches its default branch for todo stores")
        .accessibilityIdentifier("repository.option.\(repository.stableID)")
    }

    private var branchSection: some View {
        Section {
            TextField("Default branch", text: branchBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .disabled(model.isBusy)
                .onSubmit {
                    discoverStores()
                }
                .accessibilityLabel("Repository branch")
                .accessibilityHint("Enter a branch, then find todo stores on that branch")
                .accessibilityIdentifier("repository.branch")

            Button {
                discoverStores()
            } label: {
                Label("Find Todo Stores", systemImage: "magnifyingglass")
            }
            .disabled(!canDiscoverStores)
            .accessibilityHint("Searches this branch for todo configuration files")
            .accessibilityIdentifier("repository.discoverStores")
        } header: {
            Text("Branch")
        } footer: {
            Text("The selected repository’s default branch is filled in automatically. You can enter another branch before searching.")
        }
    }

    @ViewBuilder
    private var storeSection: some View {
        Section {
            if needsStoreRefresh {
                ContentUnavailableView {
                    Label("Search this branch", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Find todo stores again after changing the repository or branch.")
                }
                .accessibilityIdentifier("repository.storeRefreshRequired")
            } else if model.discoveredStorePaths.isEmpty {
                if model.isBusy {
                    ProgressView("Searching for todo stores…")
                        .accessibilityIdentifier("repository.storeLoading")
                } else {
                    ContentUnavailableView {
                        Label("No todo stores found", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text("Choose a branch containing a .todo/config.toml file, then search again.")
                    }
                    .accessibilityIdentifier("repository.storeEmpty")
                }
            } else {
                ForEach(model.discoveredStorePaths, id: \.self) { path in
                    storeButton(path: path)
                }
            }
        } header: {
            Text("Todo Store")
        } footer: {
            if !needsStoreRefresh, !model.discoveredStorePaths.isEmpty {
                Text("Each result contains a .todo/config.toml configuration file.")
            }
        }
    }

    private func storeButton(path: String) -> some View {
        let isSelected = model.storePath == path
        let title = path.isEmpty ? "Repository root" : path
        let configPath = path.isEmpty ? ".todo/config.toml" : "\(path)/.todo/config.toml"

        return Button {
            model.storePath = path
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(configPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected ? OTodoTheme.accent.opacity(0.10) : OTodoTheme.raisedCard
        )
        .disabled(model.isBusy)
        .accessibilityLabel("Todo store at \(title)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Selects this todo store")
        .accessibilityIdentifier("repository.store.\(path.isEmpty ? "root" : path)")
    }

    private var connectSection: some View {
        Section {
            Button {
                Task {
                    await model.connectRepository()
                }
            } label: {
                Label("Connect Repository", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canConnect)
            .accessibilityHint("Downloads the selected todo store and opens your tasks")
            .accessibilityIdentifier("repository.connect")
        } footer: {
            if needsStoreRefresh {
                Text("Search the current branch before connecting.")
            } else if model.discoveredStorePaths.isEmpty {
                Text("Select a discovered todo store before connecting.")
            }
        }
        .listRowBackground(Color.clear)
    }

    private var branchBinding: Binding<String> {
        Binding(
            get: { model.branch },
            set: { newValue in
                model.branch = newValue
                needsStoreRefresh = true
            }
        )
    }

    private var canDiscoverStores: Bool {
        model.selectedRepositoryID != nil
            && !model.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isBusy
    }

    private var canConnect: Bool {
        model.selectedRepositoryID != nil
            && !model.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.discoveredStorePaths.contains(model.storePath)
            && !needsStoreRefresh
            && !model.isBusy
    }

    private func selectRepository(_ id: String) {
        needsStoreRefresh = true
        Task {
            await model.selectRepository(id: id)
            if model.selectedRepositoryID == id, model.errorMessage == nil {
                needsStoreRefresh = false
            }
        }
    }

    private func discoverStores() {
        guard canDiscoverStores else { return }
        needsStoreRefresh = true
        Task {
            let selectedID = model.selectedRepositoryID
            await model.selectRepository(id: selectedID)
            if model.selectedRepositoryID == selectedID, model.errorMessage == nil {
                needsStoreRefresh = false
            }
        }
    }

    private func retryCurrentStep() {
        Task {
            if let selectedID = model.selectedRepositoryID {
                needsStoreRefresh = true
                await model.selectRepository(id: selectedID)
                if model.selectedRepositoryID == selectedID, model.errorMessage == nil {
                    needsStoreRefresh = false
                }
            } else {
                await model.loadRepositories()
            }
        }
    }
}

private extension RepositorySummary {
    var stableID: String {
        "\(owner)/\(name)"
    }
}
