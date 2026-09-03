import Foundation
import OTodoCore

/// Supplies every GitHub operation with a current OAuth access token. Refresh-token
/// rotation is committed to Keychain before the new access token becomes observable.
actor AuthenticatedGitHubService: GitHubServing {
    private static let expirationLeeway: TimeInterval = 60

    private let oauthClient: GitHubOAuthClient
    private let credentialStore: any CredentialStoring
    private let apiClient: GitHubAPIClient
    private var token: OAuthTokenPair
    private var refreshTask: Task<OAuthTokenPair, Error>?
    private var generation: UInt64 = 0
    private var isInvalidated = false

    init(
        token: OAuthTokenPair,
        oauthClient: GitHubOAuthClient,
        credentialStore: any CredentialStoring
    ) {
        self.token = token
        self.oauthClient = oauthClient
        self.credentialStore = credentialStore
        apiClient = GitHubAPIClient(accessToken: token.accessToken)
    }

    func invalidate() async {
        if !isInvalidated {
            isInvalidated = true
            generation &+= 1
        }

        let task = refreshTask
        task?.cancel()
        if let task {
            _ = await task.result
        }
        refreshTask = nil
    }

    func listRepositories() async throws -> [RepositorySummary] {
        try await authenticated { client in
            try await client.listRepositories()
        }
    }

    func discoverStorePaths(
        repository: RepositorySummary,
        branch: String
    ) async throws -> [String] {
        try await authenticated { client in
            try await client.discoverStorePaths(repository: repository, branch: branch)
        }
    }

    func fetchSnapshot(selection: RepositorySelection) async throws -> GitSnapshot {
        try await authenticated { client in
            try await client.fetchSnapshot(selection: selection)
        }
    }

    func commit(
        selection: RepositorySelection,
        changes: [RemoteChange],
        against snapshot: GitSnapshot,
        message: String
    ) async throws -> String {
        try await authenticated { client in
            try await client.commit(
                selection: selection,
                changes: changes,
                against: snapshot,
                message: message
            )
        }
    }

    func updateReference(
        selection: RepositorySelection,
        to commitSHA: String,
        expectedHead: String
    ) async throws {
        try await authenticated { client in
            try await client.updateReference(
                selection: selection,
                to: commitSHA,
                expectedHead: expectedHead
            )
        }
    }

    private func authenticated<Value: Sendable>(
        operation: @Sendable (GitHubAPIClient) async throws -> Value
    ) async throws -> Value {
        try requireValidSession()
        try await refreshIfNeeded(force: false)
        try requireValidSession()

        do {
            let value = try await operation(apiClient)
            try requireValidSession()
            return value
        } catch {
            try requireValidSession()
            guard let error = error as? OTodoError,
                  case .authentication = error
            else {
                throw error
            }
            try await refreshIfNeeded(force: true)
            try requireValidSession()
            let value = try await operation(apiClient)
            try requireValidSession()
            return value
        }
    }

    private func refreshIfNeeded(force: Bool) async throws {
        try requireValidSession()
        if !force {
            guard let accessTokenExpiresAt = token.accessTokenExpiresAt else {
                return
            }
            if accessTokenExpiresAt > Date().addingTimeInterval(Self.expirationLeeway) {
                return
            }
        }

        if let refreshTokenExpiresAt = token.refreshTokenExpiresAt,
           refreshTokenExpiresAt <= Date().addingTimeInterval(Self.expirationLeeway)
        {
            throw OTodoError.authentication(message: "The GitHub refresh token has expired")
        }
        guard token.refreshToken?.isEmpty == false else {
            throw OTodoError.authentication(message: "GitHub authorization must be renewed")
        }

        let refreshGeneration = generation
        if let refreshTask {
            let refreshed = try await refreshTask.value
            try requireValidSession(generation: refreshGeneration)
            token = refreshed
            await apiClient.updateToken(refreshed)
            return
        }

        let currentToken = token
        let oauthClient = oauthClient
        let task = Task<OAuthTokenPair, Error> {
            let refreshed = try await oauthClient.refreshToken(currentToken)
            try Task.checkCancellation()
            try await self.persist(
                refreshed,
                refreshGeneration: refreshGeneration
            )
            return refreshed
        }
        refreshTask = task

        do {
            let refreshed = try await task.value
            try requireValidSession(generation: refreshGeneration)
            refreshTask = nil
            token = refreshed
            await apiClient.updateToken(refreshed)
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func persist(
        _ refreshed: OAuthTokenPair,
        refreshGeneration: UInt64
    ) async throws {
        try Task.checkCancellation()
        try requireValidSession(generation: refreshGeneration)
        try await credentialStore.saveToken(refreshed)
        try Task.checkCancellation()
        try requireValidSession(generation: refreshGeneration)
    }

    private func requireValidSession(generation expectedGeneration: UInt64? = nil) throws {
        guard !isInvalidated,
              expectedGeneration == nil || expectedGeneration == generation
        else {
            throw OTodoError.authentication(message: "The GitHub session has ended")
        }
    }
}
