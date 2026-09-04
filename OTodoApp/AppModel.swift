import Foundation
import Observation
import OTodoCore

@MainActor
@Observable
final class AppModel {
    enum RootState: Equatable {
        case missingOAuthConfiguration
        case authentication
        case onboarding
        case workspace
    }

    private(set) var rootState: RootState
    let gitHubClientID: String?

    private(set) var deviceCode: OAuthDeviceCode?
    private(set) var repositories: [RepositorySummary] = []
    private(set) var selectedRepositoryID: String?
    var branch = ""
    var storePath = ""
    private(set) var discoveredStorePaths: [String] = []

    private(set) var tasks: [TodoTask] = []
    private(set) var configuration: StoreConfiguration?
    private(set) var projectChoices: [String] = []

    private(set) var pendingChangeCount = 0
    private(set) var conflictCount = 0
    private(set) var conflicts: [SyncConflict] = []
    private(set) var isOnline: Bool
    private(set) var isBusy = false
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?

    @ObservationIgnored private let isUITesting: Bool
    @ObservationIgnored private let resetsUITestingWorkspace: Bool
    @ObservationIgnored private let workspaceRootURL: URL
    @ObservationIgnored private let workspaceStore: FileWorkspaceStore
    @ObservationIgnored private let taskService: TaskWorkspaceService
    @ObservationIgnored private let credentialStore: (any CredentialStoring)?
    @ObservationIgnored private let repositorySelectionStore: RepositorySelectionStore?
    @ObservationIgnored private let oauthClient: GitHubOAuthClient?
    @ObservationIgnored private let connectivityMonitor: ConnectivityMonitor?

    @ObservationIgnored private var authenticatedGitHub: AuthenticatedGitHubService?
    @ObservationIgnored private var syncEngine: SyncEngine?
    @ObservationIgnored private var workspaceSelection: RepositorySelection?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var authorizationID: UUID?
    @ObservationIgnored private var authorizationTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncFollowUpRequested = false
    @ObservationIgnored private var syncFollowUpSurfacesErrors = false
    @ObservationIgnored private var localMutationsInProgress = 0
    @ObservationIgnored private var isEndingSession = false
    @ObservationIgnored private var connectivityTask: Task<Void, Never>?

    init(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        launchArguments: [String] = ProcessInfo.processInfo.arguments
    ) {
#if DEBUG
        let isUITesting = launchArguments.contains("-ui-testing")
#else
        let isUITesting = false
#endif
        self.isUITesting = isUITesting
        resetsUITestingWorkspace =
            isUITesting && launchArguments.contains("-ui-testing-reset-workspace")

        let clientID = Self.configuredClientID(in: infoDictionary)
        gitHubClientID = clientID

        let rootURL: URL
#if DEBUG
        if isUITesting {
            rootURL = URL.applicationSupportDirectory
                .appendingPathComponent(
                    "plastickarma.otodo-ui-testing",
                    isDirectory: true
                )
        } else {
            rootURL = URL.applicationSupportDirectory
                .appendingPathComponent("plastickarma.otodo", isDirectory: true)
                .appendingPathComponent("workspaces", isDirectory: true)
        }
#else
        rootURL = URL.applicationSupportDirectory
            .appendingPathComponent("plastickarma.otodo", isDirectory: true)
            .appendingPathComponent("workspaces", isDirectory: true)
#endif
        workspaceRootURL = rootURL

        let store = FileWorkspaceStore(rootURL: rootURL)
        workspaceStore = store
        taskService = TaskWorkspaceService(
            persistence: store,
            taskCodec: ObsidianTaskCodec()
        )

#if DEBUG
        if isUITesting {
            credentialStore = nil
            repositorySelectionStore = nil
            oauthClient = nil
            connectivityMonitor = nil
            isOnline = false
            rootState = .workspace
        } else {
            let credentials = KeychainCredentialStore()
            credentialStore = credentials
            repositorySelectionStore = RepositorySelectionStore()
            oauthClient = clientID.map {
                GitHubOAuthClient(clientID: $0)
            }
            let monitor = ConnectivityMonitor()
            connectivityMonitor = monitor
            isOnline = monitor.currentConnectivity
            rootState = clientID == nil ? .missingOAuthConfiguration : .authentication
        }
#else
        let credentials = KeychainCredentialStore()
        credentialStore = credentials
        repositorySelectionStore = RepositorySelectionStore()
        oauthClient = clientID.map {
            GitHubOAuthClient(clientID: $0)
        }
        let monitor = ConnectivityMonitor()
        connectivityMonitor = monitor
        isOnline = monitor.currentConnectivity
        rootState = clientID == nil ? .missingOAuthConfiguration : .authentication
#endif
    }

    func start() async {
        guard !didStart else { return }
        didStart = true

#if DEBUG
        if isUITesting {
            await startUITestingWorkspace()
            return
        }
#endif

        startConnectivityObservation()
        guard gitHubClientID != nil,
              let credentialStore,
              let repositorySelectionStore,
              oauthClient != nil
        else {
            rootState = .missingOAuthConfiguration
            return
        }

        let operationSession = sessionID
        var restoredWorkspace = false
        do {
            if let selection = try await repositorySelectionStore.load() {
                guard sessionID == operationSession, !isEndingSession else { return }
                workspaceSelection = selection
                if let workspace = try await taskService.load(selection: selection) {
                    guard sessionID == operationSession, !isEndingSession else { return }
                    apply(workspace)
                    rootState = .workspace
                    restoredWorkspace = true
                }
            }

            let storedToken = try await credentialStore.loadToken()
            guard sessionID == operationSession, !isEndingSession else { return }
            guard let token = storedToken else {
                if restoredWorkspace {
                    rootState = .workspace
                    statusMessage = "Saved todos remain available offline."
                    errorMessage = "GitHub authorization is required. Sign out, then authorize again to synchronize."
                } else {
                    rootState = .authentication
                }
                return
            }
            if let refreshExpiration = token.refreshTokenExpiresAt,
               refreshExpiration <= Date()
            {
                try await credentialStore.clearToken()
                guard sessionID == operationSession, !isEndingSession else { return }
                if restoredWorkspace {
                    rootState = .workspace
                    statusMessage = "Saved todos remain available offline."
                    errorMessage = "GitHub authorization expired. Sign out, then authorize again to synchronize."
                } else {
                    rootState = .authentication
                    errorMessage = "GitHub authorization expired. Sign in again to continue."
                }
                return
            }

            configureAuthenticatedGitHub(with: token)
            if restoredWorkspace {
                errorMessage = nil
                statusMessage = isOnline ? "Checking for changes…" : "Offline — showing saved todos."
                if isOnline {
                    triggerSynchronization(surfacesErrors: true)
                }
            } else {
                if workspaceSelection != nil {
                    try await repositorySelectionStore.clear()
                    guard sessionID == operationSession, !isEndingSession else { return }
                    workspaceSelection = nil
                }
                rootState = .onboarding
                statusMessage = nil
            }
        } catch {
            guard sessionID == operationSession, !isEndingSession else { return }
            if restoredWorkspace {
                errorMessage = "\(Self.message(for: error)) Sign out, then authorize again to synchronize."
                rootState = .workspace
            } else {
                errorMessage = Self.message(for: error)
                rootState = .authentication
            }
        }
    }

    func sceneDidBecomeActive() async {
        await start()
        guard rootState == .workspace, let selection = workspaceSelection else { return }
        let operationSession = sessionID
        do {
            if let workspace = try await taskService.load(selection: selection) {
                guard sessionID == operationSession, !isEndingSession else { return }
                apply(workspace)
            }
        } catch {
            guard sessionID == operationSession, !isEndingSession else { return }
            errorMessage = Self.message(for: error)
        }
        guard sessionID == operationSession, !isEndingSession else { return }
        if isOnline {
            await synchronize(surfacesErrors: true)
        }
    }

    func startAuthorization() async {
        guard !isEndingSession else { return }
        guard let oauthClient, let credentialStore, let repositorySelectionStore else {
            rootState = .missingOAuthConfiguration
            return
        }

        isEndingSession = true
        sessionID = UUID()
        let preparationSession = sessionID
        let activeSync = syncTask
        let activeGitHub = authenticatedGitHub
        syncTask = nil
        syncFollowUpRequested = false
        syncFollowUpSurfacesErrors = false
        activeSync?.cancel()
        authenticatedGitHub = nil
        syncEngine = nil
        workspaceSelection = nil
        tasks = []
        configuration = nil
        projectChoices = []
        pendingChangeCount = 0
        conflictCount = 0
        conflicts = []
        rootState = .authentication

        await cancelAuthorization()
        await activeGitHub?.invalidate()
        await activeSync?.value
        guard sessionID == preparationSession, isEndingSession else { return }
        do {
            try await repositorySelectionStore.clear()
            guard sessionID == preparationSession, isEndingSession else { return }
            try await credentialStore.clearToken()
        } catch {
            guard sessionID == preparationSession else { return }
            isEndingSession = false
            errorMessage = Self.message(for: error)
            return
        }
        guard sessionID == preparationSession, isEndingSession else { return }
        isEndingSession = false

        let operationID = UUID()
        authorizationID = operationID
        deviceCode = nil
        errorMessage = nil
        statusMessage = "Requesting a GitHub authorization code…"
        isBusy = true

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAuthorization(
                operationID: operationID,
                oauthClient: oauthClient,
                credentialStore: credentialStore
            )
        }
        authorizationTask = task
        await task.value
        if authorizationID == operationID {
            authorizationTask = nil
        }
    }

    func cancelAuthorization() async {
        authorizationID = nil
        let task = authorizationTask
        authorizationTask = nil
        task?.cancel()
        await task?.value
        deviceCode = nil
        isBusy = false
        statusMessage = nil
    }

    func loadRepositories() async {
        guard let authenticatedGitHub else { return }
        let operationSession = sessionID
        errorMessage = nil
        statusMessage = "Loading repositories…"
        isBusy = true
        defer {
            if sessionID == operationSession {
                isBusy = false
            }
        }

        do {
            let loaded = try await authenticatedGitHub.listRepositories()
            guard sessionID == operationSession else { return }
            repositories = loaded
            statusMessage = loaded.isEmpty ? "No repositories are available to this account." : nil
        } catch {
            await handleNetworkError(error, session: operationSession)
        }
    }

    func selectRepository(id: String?) async {
        guard let id else {
            selectedRepositoryID = nil
            branch = ""
            storePath = ""
            discoveredStorePaths = []
            return
        }
        guard let repository = repositories.first(where: { Self.repositoryID($0) == id }) else {
            errorMessage = "The selected repository is no longer available."
            return
        }
        guard let authenticatedGitHub else { return }

        let operationSession = sessionID
        let isNewSelection = selectedRepositoryID != id
        selectedRepositoryID = id
        if isNewSelection {
            branch = repository.defaultBranch
        }
        let requestedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedBranch.isEmpty else {
            errorMessage = "Enter a repository branch."
            return
        }

        errorMessage = nil
        statusMessage = "Searching for todo stores…"
        discoveredStorePaths = []
        if isNewSelection {
            storePath = ""
        }
        isBusy = true
        defer {
            if sessionID == operationSession {
                isBusy = false
            }
        }

        do {
            let paths = try await authenticatedGitHub.discoverStorePaths(
                repository: repository,
                branch: requestedBranch
            )
            guard sessionID == operationSession, selectedRepositoryID == id else { return }
            branch = requestedBranch
            discoveredStorePaths = paths
            if !paths.contains(storePath) {
                storePath = paths.first ?? ""
            }
            statusMessage = paths.isEmpty ? "No todo stores were found on this branch." : nil
        } catch {
            await handleNetworkError(error, session: operationSession)
        }
    }

    func connectRepository() async {
        guard let selectedRepositoryID,
              let repository = repositories.first(where: {
                  Self.repositoryID($0) == selectedRepositoryID
              }),
              let authenticatedGitHub,
              let repositorySelectionStore
        else {
            errorMessage = "Choose a repository before connecting."
            return
        }

        let operationSession = sessionID
        errorMessage = nil
        statusMessage = "Downloading and validating the todo store…"
        isBusy = true
        defer {
            if sessionID == operationSession {
                isBusy = false
            }
        }

        do {
            let selection = try RepositorySelection(
                owner: repository.owner,
                name: repository.name,
                branch: branch.trimmingCharacters(in: .whitespacesAndNewlines),
                storePath: storePath
            )
            let engine = SyncEngine(
                gitHub: authenticatedGitHub,
                persistence: workspaceStore,
                configCodec: StrictStoreConfigCodec(),
                taskCodec: ObsidianTaskCodec()
            )
            let loadedCachedWorkspace: Bool
            let workspace: WorkspaceState
            if let existing = try await taskService.load(selection: selection) {
                workspace = existing
                loadedCachedWorkspace = true
            } else {
                workspace = try await engine.initialPull(selection: selection)
                loadedCachedWorkspace = false
            }
            guard sessionID == operationSession else { return }

            try await repositorySelectionStore.save(selection)
            guard sessionID == operationSession else { return }
            workspaceSelection = selection
            syncEngine = engine
            apply(workspace)
            rootState = .workspace
            statusMessage = "Todo store is ready."
            errorMessage = nil
            if loadedCachedWorkspace, isOnline {
                triggerSynchronization(surfacesErrors: true)
            }
        } catch {
            await handleNetworkError(error, session: operationSession)
        }
    }

    func createTask(draft: TaskEditorDraft) async {
        guard rootState == .workspace, let selection = workspaceSelection else {
            errorMessage = "No todo workspace is selected."
            return
        }
        let operationSession = sessionID

        beginLocalMutation()
        defer { finishLocalMutation() }
        errorMessage = nil
        statusMessage = "Saving todo on this device…"
        isBusy = true
        do {
            _ = try await taskService.addTask(
                selection: selection,
                name: draft.name,
                state: draft.state,
                projectSlugs: draft.projectSlugs,
                tags: draft.tags,
                dueDate: draft.dueDate,
                body: draft.body
            )
            guard sessionID == operationSession else { return }
            syncFollowUpRequested = true
            let workspace = try await taskService.loadWorkspace(selection: selection)
            guard sessionID == operationSession else { return }
            apply(workspace)
            errorMessage = nil
            publishLocalSaveStatus(
                onlineMessage: "Saved on this device; waiting to sync.",
                offlineMessage: "Saved on this device while offline."
            )
            isBusy = false
        } catch {
            guard sessionID == operationSession else { return }
            isBusy = false
            errorMessage = Self.message(for: error)
            statusMessage = nil
        }
    }

    func updateTask(id: TaskID, draft: TaskEditorDraft) async {
        guard rootState == .workspace, let selection = workspaceSelection else {
            errorMessage = "No todo workspace is selected."
            return
        }
        guard let expectedTask = draft.preservedTask else {
            errorMessage = "The original todo is unavailable. Close the editor and try again."
            return
        }
        let operationSession = sessionID

        beginLocalMutation()
        defer { finishLocalMutation() }
        errorMessage = nil
        statusMessage = "Saving todo on this device…"
        isBusy = true
        do {
            _ = try await taskService.editTask(
                selection: selection,
                id: id,
                expectedTask: expectedTask,
                update: TaskUpdate(
                    name: draft.name,
                    state: draft.state,
                    projectSlugs: draft.projectSlugs,
                    tags: draft.tags,
                    dueDate: draft.dueDate,
                    body: draft.body
                )
            )
            guard sessionID == operationSession else { return }
            syncFollowUpRequested = true
            let workspace = try await taskService.loadWorkspace(selection: selection)
            guard sessionID == operationSession else { return }
            apply(workspace)
            errorMessage = nil
            publishLocalSaveStatus(
                onlineMessage: "Saved on this device; waiting to sync.",
                offlineMessage: "Saved on this device while offline."
            )
            isBusy = false
        } catch {
            guard sessionID == operationSession else { return }
            isBusy = false
            errorMessage = Self.message(for: error)
            statusMessage = nil
        }
    }
    func resolveConflict(
        path: String,
        resolution: WorkspaceConflictResolution
    ) async {
        guard rootState == .workspace, let selection = workspaceSelection else {
            errorMessage = "No todo workspace is selected."
            return
        }

        let operationSession = sessionID
        beginLocalMutation()
        defer { finishLocalMutation() }
        errorMessage = nil
        statusMessage = "Resolving conflict on this device…"
        isBusy = true
        do {
            let workspace = try await taskService.resolveConflict(
                selection: selection,
                path: path,
                resolution: resolution
            )
            guard sessionID == operationSession else { return }
            syncFollowUpRequested = true
            apply(workspace)
            errorMessage = nil
            isBusy = false
            publishLocalSaveStatus(
                onlineMessage: "Conflict resolved on this device; waiting to sync.",
                offlineMessage: "Conflict resolved on this device while offline."
            )
        } catch {
            guard sessionID == operationSession else { return }
            isBusy = false
            errorMessage = Self.message(for: error)
            statusMessage = nil
        }
    }

    func refresh() async {
        guard let selection = workspaceSelection else { return }
        let operationSession = sessionID
        errorMessage = nil
        do {
            if let workspace = try await taskService.load(selection: selection) {
                guard sessionID == operationSession, !isEndingSession else { return }
                apply(workspace)
            }
        } catch {
            guard sessionID == operationSession, !isEndingSession else { return }
            errorMessage = Self.message(for: error)
            return
        }
        guard authenticatedGitHub != nil else {
            statusMessage = "Saved todos remain available on this device."
            errorMessage = "GitHub authorization is required. Sign out, then authorize again to synchronize."
            return
        }

        guard sessionID == operationSession, !isEndingSession else { return }
        guard isOnline else {
            statusMessage = "Offline — showing saved todos."
            return
        }
        await synchronize(surfacesErrors: true)
    }

    func signOut() async {
        guard !isEndingSession else { return }
        isEndingSession = true
        sessionID = UUID()
        let activeSync = syncTask
        let activeGitHub = authenticatedGitHub
        syncTask = nil
        syncFollowUpRequested = false
        syncFollowUpSurfacesErrors = false
        activeSync?.cancel()
        authenticatedGitHub = nil
        syncEngine = nil
        workspaceSelection = nil
        rootState = gitHubClientID == nil ? .missingOAuthConfiguration : .authentication

        await cancelAuthorization()
        await activeGitHub?.invalidate()
        await activeSync?.value

        var clearingError: Error?
        if let repositorySelectionStore {
            do {
                try await repositorySelectionStore.clear()
            } catch {
                clearingError = error
            }
        }
        if let credentialStore {
            do {
                try await credentialStore.clearToken()
            } catch {
                clearingError = clearingError ?? error
            }
        }

        repositories = []
        selectedRepositoryID = nil
        branch = ""
        storePath = ""
        discoveredStorePaths = []
        tasks = []
        configuration = nil
        projectChoices = []
        pendingChangeCount = 0
        conflictCount = 0
        conflicts = []
        isBusy = false
        statusMessage = nil
        errorMessage = clearingError.map(Self.message(for:))
        isEndingSession = false
    }

    private func runAuthorization(
        operationID: UUID,
        oauthClient: GitHubOAuthClient,
        credentialStore: any CredentialStoring
    ) async {
        var tokenWasPersisted = false
        do {
            let code = try await oauthClient.startDeviceFlow()
            try Task.checkCancellation()
            guard authorizationID == operationID else { return }
            deviceCode = code
            statusMessage = "Waiting for approval in GitHub…"

            let token = try await oauthClient.pollForToken(deviceCode: code)
            try Task.checkCancellation()
            guard authorizationID == operationID else { return }
            try await credentialStore.saveToken(token)
            tokenWasPersisted = true
            try Task.checkCancellation()
            guard authorizationID == operationID else {
                try? await credentialStore.clearToken()
                return
            }

            sessionID = UUID()
            configureAuthenticatedGitHub(with: token)
            deviceCode = nil
            isBusy = false
            statusMessage = nil
            errorMessage = nil
            rootState = .onboarding
        } catch is CancellationError {
            if tokenWasPersisted {
                try? await credentialStore.clearToken()
            }
            // Cancellation deliberately publishes no terminal state. The canceling
            // operation owns clearing the visible authorization values.
        } catch {
            guard authorizationID == operationID else { return }
            isBusy = false
            statusMessage = nil
            errorMessage = Self.message(for: error)
        }
    }


    private func configureAuthenticatedGitHub(with token: OAuthTokenPair) {
        guard let oauthClient, let credentialStore else { return }
        let github = AuthenticatedGitHubService(
            token: token,
            oauthClient: oauthClient,
            credentialStore: credentialStore
        )
        authenticatedGitHub = github
        syncEngine = SyncEngine(
            gitHub: github,
            persistence: workspaceStore,
            configCodec: StrictStoreConfigCodec(),
            taskCodec: ObsidianTaskCodec()
        )
    }

    private func apply(_ workspace: WorkspaceState) {
        workspaceSelection = workspace.selection
        configuration = workspace.configuration
        projectChoices = workspace.knownProjectSlugs.sorted()
        tasks = workspace.tasks.map(\.task)
        conflicts = workspace.conflicts
        pendingChangeCount = workspace.pendingChanges.count
        conflictCount = workspace.conflicts.count
    }

    private func triggerSynchronization(surfacesErrors: Bool) {
        Task { [weak self] in
            guard let self else { return }
            await self.synchronize(surfacesErrors: surfacesErrors)
        }
    }
    private func synchronize(surfacesErrors: Bool) async {
        guard !isUITesting,
              !isEndingSession,
              isOnline,
              workspaceSelection != nil,
              syncEngine != nil
        else { return }

        if localMutationsInProgress > 0 {
            syncFollowUpRequested = true
            syncFollowUpSurfacesErrors = syncFollowUpSurfacesErrors || surfacesErrors
            return
        }
        if let activeSync = syncTask {
            syncFollowUpRequested = true
            syncFollowUpSurfacesErrors = syncFollowUpSurfacesErrors || surfacesErrors
            await activeSync.value
            return
        }

        let effectiveSurfacesErrors = surfacesErrors || syncFollowUpSurfacesErrors
        syncFollowUpRequested = false
        syncFollowUpSurfacesErrors = false
        let operationSession = sessionID
        isBusy = true
        statusMessage = "Synchronizing with GitHub…"
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performSynchronization(
                session: operationSession,
                surfacesErrors: effectiveSurfacesErrors
            )
        }
        syncTask = task
        await task.value
        guard sessionID == operationSession, !isEndingSession else { return }
        syncTask = nil

        if syncFollowUpRequested {
            let followUpSurfacesErrors = syncFollowUpSurfacesErrors
            await synchronize(surfacesErrors: followUpSurfacesErrors)
        }
    }

    private func performSynchronization(session operationSession: UUID, surfacesErrors: Bool) async {
        guard let selection = workspaceSelection, let syncEngine else { return }
        do {
            let report = try await syncEngine.sync(selection: selection)
            try Task.checkCancellation()
            let workspace = try await taskService.loadWorkspace(selection: selection)
            guard sessionID == operationSession else { return }
            apply(workspace)
            errorMessage = nil
            if report.conflicts.isEmpty {
                statusMessage = Self.syncDescription(report)
            } else {
                statusMessage = "Synchronization found \(report.conflicts.count) conflict\(report.conflicts.count == 1 ? "" : "s")."
            }
        } catch is CancellationError {
            return
        } catch {
            guard sessionID == operationSession else { return }
            if let workspace = try? await taskService.load(selection: selection) {
                apply(workspace)
            }
            if Self.isAuthenticationError(error) {
                await returnToAuthentication(because: error)
                return
            }
            if surfacesErrors {
                errorMessage = Self.message(for: error)
                statusMessage = "Synchronization could not finish. Saved changes remain on this device."
            } else {
                statusMessage = "Saved locally; synchronization will retry later. \(Self.message(for: error))"
            }
        }
        if sessionID == operationSession {
            isBusy = false
        }
    }

    private func handleNetworkError(_ error: Error, session operationSession: UUID) async {
        guard sessionID == operationSession else { return }
        if Self.isAuthenticationError(error) {
            await returnToAuthentication(because: error)
        } else {
            errorMessage = Self.message(for: error)
            statusMessage = nil
        }
    }

    private func returnToAuthentication(because error: Error) async {
        isEndingSession = true
        sessionID = UUID()
        let operationSession = sessionID
        let activeSync = syncTask
        let activeGitHub = authenticatedGitHub
        syncTask = nil
        syncFollowUpRequested = false
        syncFollowUpSurfacesErrors = false
        activeSync?.cancel()
        authenticatedGitHub = nil
        syncEngine = nil
        deviceCode = nil
        repositories = []
        selectedRepositoryID = nil
        branch = ""
        storePath = ""
        discoveredStorePaths = []

        await activeGitHub?.invalidate()

        if let credentialStore {
            try? await credentialStore.clearToken()
        }
        guard sessionID == operationSession, isEndingSession else { return }

        isBusy = false
        if workspaceSelection != nil {
            rootState = .workspace
            statusMessage = "Saved todos remain available offline."
            errorMessage = "\(Self.message(for: error)) Sign out, then authorize again to synchronize."
        } else {
            statusMessage = nil
            errorMessage = Self.message(for: error)
            rootState = gitHubClientID == nil ? .missingOAuthConfiguration : .authentication
        }
        isEndingSession = false
    }

    private func startConnectivityObservation() {
        guard connectivityTask == nil, let connectivityMonitor else { return }
        let changes = connectivityMonitor.connectivityChanges
        connectivityTask = Task { [weak self] in
            for await online in changes {
                guard !Task.isCancelled, let self else { return }
                await self.connectivityDidChange(online)
            }
        }
    }

    private func connectivityDidChange(_ online: Bool) {
        let wasOnline = isOnline
        isOnline = online
        guard rootState == .workspace else { return }
        if !online {
            statusMessage = "Offline — changes are saved locally."
        } else if !wasOnline {
            triggerSynchronization(surfacesErrors: true)
        }
    }

    private func beginLocalMutation() {
        localMutationsInProgress += 1
        if let activeSync = syncTask {
            syncFollowUpRequested = true
            activeSync.cancel()
        }
    }

    private func finishLocalMutation() {
        localMutationsInProgress -= 1
        guard localMutationsInProgress == 0,
              isOnline,
              syncFollowUpRequested
        else { return }
        triggerSynchronization(surfacesErrors: false)
    }

    private func publishLocalSaveStatus(
        onlineMessage: String,
        offlineMessage: String
    ) {
        if authenticatedGitHub == nil {
            statusMessage = "Saved on this device. Sign out, then authorize again to synchronize."
            errorMessage = nil
        } else {
            statusMessage = isOnline ? onlineMessage : offlineMessage
        }
    }

#if DEBUG
    private func startUITestingWorkspace() async {
        do {
            let fileManager = FileManager.default
            if resetsUITestingWorkspace,
               fileManager.fileExists(atPath: workspaceRootURL.path)
            {
                try fileManager.removeItem(at: workspaceRootURL)
            }

            let selection = try RepositorySelection(
                owner: "ui-testing",
                name: "seeded-workspace",
                branch: "main",
                storePath: ""
            )
            let configuration = try StoreConfiguration(
                schemaVersion: 1,
                tasksDirectory: "todos",
                projectsDirectory: "projects",
                obsidianLinkPrefix: "",
                defaultState: "todo",
                states: [
                    try WorkflowState(id: "todo", name: "Pending", isTerminal: false),
                    try WorkflowState(id: "done", name: "Done", isTerminal: true),
                ]
            )
            let restored: WorkspaceState
            if let existing = try await taskService.load(selection: selection) {
                restored = existing
            } else {
                let seeds: [(id: String, name: String, state: String, dueDate: CivilDate?)] = [
                    ("01ARZ3NDEKTSV4RRFFQ69G5FAV", "Seed todo", "todo", try Self.uiTestDate()),
                    ("01ARZ3NDEKTSV4RRFFQ69G5FAW", "Overdue todo", "todo", try Self.uiTestDate(dayOffset: -1)),
                    ("01ARZ3NDEKTSV4RRFFQ69G5FAX", "Future todo", "todo", try Self.uiTestDate(dayOffset: 1)),
                    ("01ARZ3NDEKTSV4RRFFQ69G5FAY", "Undated todo", "todo", nil),
                    ("01ARZ3NDEKTSV4RRFFQ69G5FAZ", "Completed overdue todo", "done", try Self.uiTestDate(dayOffset: -1)),
                ]
                let codec = ObsidianTaskCodec()
                let documents = try seeds.map { seed in
                    let id = try TaskID(rawValue: seed.id)
                    let task = try TodoTask(
                        id: id,
                        relativePath: "todos/\(id.rawValue).md",
                        name: seed.name,
                        state: seed.state,
                        projectSlugs: ["home"],
                        tags: [],
                        dueDate: seed.dueDate,
                        recurrence: nil,
                        recurrenceFrom: nil,
                        lastCompletedDate: nil,
                        body: "",
                        extraProperties: [
                            YAMLProperty(name: "base", value: .string(configuration.todosBaseLink)),
                        ]
                    )
                    let content = try codec.serializeTask(task, configuration: configuration)
                    return TaskDocument(task: task, content: content, blobSHA: "seed-\(id.rawValue)")
                }
                let workspace = try WorkspaceState(
                    selection: selection,
                    configuration: configuration,
                    knownProjectSlugs: ["home"],
                    tasks: documents,
                    baseHeadCommitSHA: "seed-head",
                    baseRootTreeSHA: "seed-tree",
                    pendingChanges: [],
                    conflicts: []
                )
                try await workspaceStore.save(workspace, expectedRevision: nil)
                restored = try await taskService.loadWorkspace(selection: selection)
            }
            apply(restored)
            rootState = .workspace
            isOnline = false
            isBusy = false
            errorMessage = nil
            statusMessage = "Offline UI test workspace"
        } catch {
            rootState = .workspace
            isOnline = false
            isBusy = false
            errorMessage = Self.message(for: error)
            statusMessage = nil
        }
    }

    private static func uiTestDate(dayOffset: Int = 0) throws -> CivilDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        guard let date = calendar.date(byAdding: .day, value: dayOffset, to: Date()) else {
            throw OTodoError.corruptLocalState(message: "Could not create the UI test date")
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            throw OTodoError.corruptLocalState(message: "Could not read the UI test date")
        }
        return try CivilDate(rawValue: String(format: "%04d-%02d-%02d", year, month, day))
    }
#endif

    private static func repositoryID(_ repository: RepositorySummary) -> String {
        "\(repository.owner)/\(repository.name)"
    }

    private static func syncDescription(_ report: SyncReport) -> String {
        if report.pulledCount == 0, report.pushedCount == 0 {
            return "Up to date."
        }
        var components: [String] = []
        if report.pulledCount > 0 {
            components.append("Pulled \(report.pulledCount)")
        }
        if report.pushedCount > 0 {
            components.append("pushed \(report.pushedCount)")
        }
        return components.joined(separator: ", ") + "."
    }

    private static func isAuthenticationError(_ error: Error) -> Bool {
        guard let error = error as? OTodoError else { return false }
        if case .authentication = error {
            return true
        }
        return false
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription
        {
            return description
        }
        return error.localizedDescription
    }

    private static func configuredClientID(in infoDictionary: [String: Any]) -> String? {
        guard let value = infoDictionary["GitHubClientID"] as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty,
              trimmedValue != "$(GITHUB_CLIENT_ID)"
        else {
            return nil
        }
        return trimmedValue
    }
}
