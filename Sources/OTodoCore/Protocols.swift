import Foundation

public protocol StoreConfigCoding: Sendable {
    func parseConfiguration(_ text: String) throws -> StoreConfiguration
}

public protocol TaskRecordCoding: Sendable {
    func parseTask(
        id: TaskID,
        relativePath: String,
        text: String,
        configuration: StoreConfiguration
    ) throws -> TodoTask

    func serializeTask(
        _ task: TodoTask,
        configuration: StoreConfiguration
    ) throws -> String
}

/// The transport boundary for repository discovery and immutable-snapshot Git operations.
/// Implementations must update refs without force and surface a changed expected head as
/// `OTodoError.conflict` rather than retrying a stale write.
public protocol GitHubServing: Sendable {
    func listRepositories() async throws -> [RepositorySummary]

    func discoverStorePaths(
        repository: RepositorySummary,
        branch: String
    ) async throws -> [String]

    func fetchSnapshot(selection: RepositorySelection) async throws -> GitSnapshot

    func commit(
        selection: RepositorySelection,
        changes: [RemoteChange],
        against snapshot: GitSnapshot,
        message: String
    ) async throws -> String

    func updateReference(
        selection: RepositorySelection,
        to commitSHA: String,
        expectedHead: String
    ) async throws
}

public protocol WorkspacePersisting: Sendable {
    func load(selection: RepositorySelection) async throws -> WorkspaceState?
    func save(_ workspace: WorkspaceState, expectedRevision: UInt64?) async throws
}

public protocol CredentialStoring: Sendable {
    func loadToken() async throws -> OAuthTokenPair?
    func saveToken(_ token: OAuthTokenPair) async throws
    func clearToken() async throws
}

public protocol ULIDGenerating: Sendable {
    func generate(at date: Date) throws -> TaskID
}
