import Foundation

public enum OTodoError: Error, Sendable, Equatable, Codable {
    case validation(field: String, message: String)
    case unsupportedSchema(found: Int, supported: Int)
    case authentication(message: String)
    case transport(statusCode: Int?, message: String)
    case conflict(message: String)
    case notFound(resource: String)
    case corruptLocalState(message: String)
}

extension OTodoError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .validation(field, message):
            "Invalid \(field): \(message)"
        case let .unsupportedSchema(found, supported):
            "Unsupported store schema version \(found); this client supports version \(supported)"
        case let .authentication(message):
            "Authentication failed: \(message)"
        case let .transport(statusCode, message):
            statusCode.map { "Transport failed (HTTP \($0)): \(message)" } ?? "Transport failed: \(message)"
        case let .conflict(message):
            "Synchronization conflict: \(message)"
        case let .notFound(resource):
            "Not found: \(resource)"
        case let .corruptLocalState(message):
            "Corrupt local state: \(message)"
        }
    }
}

public struct CivilDate: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) throws {
        let bytes = Array(rawValue.utf8)
        guard bytes.count == 10,
              bytes[4] == 45,
              bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (48 ... 57).contains(byte)
              })
        else {
            throw OTodoError.validation(field: "date", message: "Expected YYYY-MM-DD")
        }

        let year = Self.number(bytes, 0 ..< 4)
        let month = Self.number(bytes, 5 ..< 7)
        let day = Self.number(bytes, 8 ..< 10)
        let daysInMonth: Int
        switch month {
        case 1, 3, 5, 7, 8, 10, 12:
            daysInMonth = 31
        case 4, 6, 9, 11:
            daysInMonth = 30
        case 2:
            let leapYear = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
            daysInMonth = leapYear ? 29 : 28
        default:
            throw OTodoError.validation(field: "date", message: "Month is outside 01...12")
        }
        guard day > 0, day <= daysInMonth else {
            throw OTodoError.validation(field: "date", message: "Not a valid proleptic Gregorian date")
        }

        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func number(_ bytes: [UInt8], _ range: Range<Int>) -> Int {
        range.reduce(into: 0) { result, index in
            result = result * 10 + Int(bytes[index] - 48)
        }
    }
}

public struct WorkflowState: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let isTerminal: Bool

    public init(id: String, name: String, isTerminal: Bool) throws {
        try DomainValidation.validateStateID(id, field: "state.id")
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OTodoError.validation(field: "state.name", message: "State names must not be empty")
        }
        guard !name.contains("\n"), !name.contains("\r") else {
            throw OTodoError.validation(field: "state.name", message: "State names must be a single line")
        }
        self.id = id
        self.name = name
        self.isTerminal = isTerminal
    }

    private enum CodingKeys: String, CodingKey { case id, name, isTerminal }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            isTerminal: container.decode(Bool.self, forKey: .isTerminal)
        )
    }
}

public struct StoreConfiguration: Sendable, Codable, Equatable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let tasksDirectory: String
    public let projectsDirectory: String
    public let obsidianLinkPrefix: String
    public let defaultState: String
    public let states: [WorkflowState]

    public init(
        schemaVersion: Int,
        tasksDirectory: String,
        projectsDirectory: String,
        obsidianLinkPrefix: String,
        defaultState: String,
        states: [WorkflowState]
    ) throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw OTodoError.unsupportedSchema(found: schemaVersion, supported: Self.supportedSchemaVersion)
        }
        try DomainValidation.validateManagedDirectory(tasksDirectory, field: "tasksDirectory")
        try DomainValidation.validateManagedDirectory(projectsDirectory, field: "projectsDirectory")
        guard !projectsDirectory.contains(where: { "[]|#^".contains($0) }) else {
            throw OTodoError.validation(
                field: "projectsDirectory",
                message: "Project directory components cannot contain [, ], |, #, or ^"
            )
        }
        guard tasksDirectory != projectsDirectory,
              !tasksDirectory.hasPrefix(projectsDirectory + "/"),
              !projectsDirectory.hasPrefix(tasksDirectory + "/")
        else {
            throw OTodoError.validation(
                field: "tasksDirectory",
                message: "Task and project directories must be distinct and non-overlapping"
            )
        }
        if !obsidianLinkPrefix.isEmpty {
            try DomainValidation.validateRelativePath(obsidianLinkPrefix, field: "obsidianLinkPrefix")
            guard !obsidianLinkPrefix.contains(where: { "[]|#^".contains($0) }) else {
                throw OTodoError.validation(
                    field: "obsidianLinkPrefix",
                    message: "Obsidian link prefixes cannot contain [, ], |, #, or ^"
                )
            }
        }
        guard !states.isEmpty else {
            throw OTodoError.validation(field: "states", message: "At least one state is required")
        }
        guard Set(states.map(\.id)).count == states.count else {
            throw OTodoError.validation(field: "states", message: "State IDs must be unique")
        }
        guard let defaultWorkflowState = states.first(where: { $0.id == defaultState }) else {
            throw OTodoError.validation(field: "defaultState", message: "Default state is not configured")
        }
        guard !defaultWorkflowState.isTerminal else {
            throw OTodoError.validation(field: "defaultState", message: "Default state must be nonterminal")
        }
        guard states.contains(where: { !$0.isTerminal }) else {
            throw OTodoError.validation(field: "states", message: "At least one state must be nonterminal")
        }

        self.schemaVersion = schemaVersion
        self.tasksDirectory = tasksDirectory
        self.projectsDirectory = projectsDirectory
        self.obsidianLinkPrefix = obsidianLinkPrefix
        self.defaultState = defaultState
        self.states = states
    }

    public func projectLink(slug: String) throws -> String {
        try DomainValidation.validateProjectSlugs([slug])
        if obsidianLinkPrefix.isEmpty {
            return "[[\(projectsDirectory)/\(slug)]]"
        }
        return "[[\(obsidianLinkPrefix)/\(projectsDirectory)/\(slug)]]"
    }

    public var todosBaseLink: String {
        if obsidianLinkPrefix.isEmpty {
            return "[[todos.base]]"
        }
        return "[[\(obsidianLinkPrefix)/todos.base]]"
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case tasksDirectory
        case projectsDirectory
        case obsidianLinkPrefix
        case defaultState
        case states
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            tasksDirectory: container.decode(String.self, forKey: .tasksDirectory),
            projectsDirectory: container.decode(String.self, forKey: .projectsDirectory),
            obsidianLinkPrefix: container.decode(String.self, forKey: .obsidianLinkPrefix),
            defaultState: container.decode(String.self, forKey: .defaultState),
            states: container.decode([WorkflowState].self, forKey: .states)
        )
    }
}

public enum RecurrenceFrom: String, Sendable, Codable, Equatable {
    case schedule
    case completion
}

public struct TodoTask: Sendable, Codable, Equatable {
    public let id: TaskID
    public let relativePath: String
    public var name: String
    public var state: String
    public var projectSlugs: [String]
    public var tags: [String]
    public var dueDate: CivilDate?
    public var recurrence: String?
    public var recurrenceFrom: RecurrenceFrom?
    public var lastCompletedDate: CivilDate?
    public var body: String
    public var extraProperties: [YAMLProperty]

    public init(
        id: TaskID,
        relativePath: String,
        name: String,
        state: String,
        projectSlugs: [String],
        tags: [String],
        dueDate: CivilDate?,
        recurrence: String?,
        recurrenceFrom: RecurrenceFrom?,
        lastCompletedDate: CivilDate?,
        body: String,
        extraProperties: [YAMLProperty]
    ) throws {
        try DomainValidation.validateRelativePath(relativePath, field: "relativePath")
        guard relativePath.hasSuffix(".md"),
              String(relativePath.dropLast(3).split(separator: "/").last ?? "").uppercased() == id.rawValue
        else {
            throw OTodoError.validation(
                field: "relativePath",
                message: "Task path basename must match its ULID and use the .md extension"
            )
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.contains("\n"),
              !name.contains("\r")
        else {
            throw OTodoError.validation(field: "name", message: "Task name must be nonempty and single-line")
        }
        try DomainValidation.validateStateID(state, field: "state")
        try DomainValidation.validateProjectSlugs(projectSlugs)
        try DomainValidation.validateTags(tags)
        try DomainValidation.validateRecurrence(
            recurrence: recurrence,
            recurrenceFrom: recurrenceFrom,
            dueDate: dueDate,
            lastCompletedDate: lastCompletedDate
        )
        try DomainValidation.validateExtraProperties(extraProperties)

        self.id = id
        self.relativePath = relativePath
        self.name = name
        self.state = state
        self.projectSlugs = projectSlugs
        self.tags = tags
        self.dueDate = dueDate
        self.recurrence = recurrence
        self.recurrenceFrom = recurrenceFrom
        self.lastCompletedDate = lastCompletedDate
        self.body = body
        self.extraProperties = extraProperties
    }

    private enum CodingKeys: String, CodingKey {
        case id, relativePath, name, state, projectSlugs, tags, dueDate, recurrence
        case recurrenceFrom, lastCompletedDate, body, extraProperties
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(TaskID.self, forKey: .id),
            relativePath: container.decode(String.self, forKey: .relativePath),
            name: container.decode(String.self, forKey: .name),
            state: container.decode(String.self, forKey: .state),
            projectSlugs: container.decode([String].self, forKey: .projectSlugs),
            tags: container.decode([String].self, forKey: .tags),
            dueDate: container.decodeIfPresent(CivilDate.self, forKey: .dueDate),
            recurrence: container.decodeIfPresent(String.self, forKey: .recurrence),
            recurrenceFrom: container.decodeIfPresent(RecurrenceFrom.self, forKey: .recurrenceFrom),
            lastCompletedDate: container.decodeIfPresent(CivilDate.self, forKey: .lastCompletedDate),
            body: container.decode(String.self, forKey: .body),
            extraProperties: container.decode([YAMLProperty].self, forKey: .extraProperties)
        )
    }
}

public struct RepositorySelection: Sendable, Codable, Equatable {
    public let owner: String
    public let name: String
    public let branch: String
    public let storePath: String

    public init(owner: String, name: String, branch: String, storePath: String) throws {
        guard !owner.isEmpty else {
            throw OTodoError.validation(field: "owner", message: "Repository owner must not be empty")
        }
        guard !name.isEmpty else {
            throw OTodoError.validation(field: "name", message: "Repository name must not be empty")
        }
        guard !branch.isEmpty, !branch.contains("\u{0000}") else {
            throw OTodoError.validation(field: "branch", message: "Branch must not be empty")
        }
        let normalizedStorePath = storePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !normalizedStorePath.isEmpty {
            try DomainValidation.validateRelativePath(normalizedStorePath, field: "storePath")
        }
        self.owner = owner
        self.name = name
        self.branch = branch
        self.storePath = normalizedStorePath
    }

    private enum CodingKeys: String, CodingKey { case owner, name, branch, storePath }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            owner: container.decode(String.self, forKey: .owner),
            name: container.decode(String.self, forKey: .name),
            branch: container.decode(String.self, forKey: .branch),
            storePath: container.decode(String.self, forKey: .storePath)
        )
    }
}

public struct RepositorySummary: Sendable, Codable, Equatable {
    public let owner: String
    public let name: String
    public let defaultBranch: String
    public let isPrivate: Bool

    public init(owner: String, name: String, defaultBranch: String, isPrivate: Bool) {
        self.owner = owner
        self.name = name
        self.defaultBranch = defaultBranch
        self.isPrivate = isPrivate
    }
}

public struct OAuthDeviceCode: Sendable, Codable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let expiresAt: Date
    public let pollingInterval: TimeInterval

    public init(
        deviceCode: String,
        userCode: String,
        verificationURI: URL,
        expiresAt: Date,
        pollingInterval: TimeInterval
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresAt = expiresAt
        self.pollingInterval = pollingInterval
    }
}

public struct OAuthTokenPair: Sendable, Codable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String
    public let scope: String?
    public let accessTokenExpiresAt: Date?
    public let refreshTokenExpiresAt: Date?

    public init(
        accessToken: String,
        refreshToken: String?,
        tokenType: String,
        scope: String?,
        accessTokenExpiresAt: Date?,
        refreshTokenExpiresAt: Date?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.scope = scope
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }
}

public struct RemoteFile: Sendable, Codable, Equatable {
    public let path: String
    public let blobSHA: String
    public let content: String

    public init(path: String, blobSHA: String, content: String) throws {
        try DomainValidation.validateRelativePath(path, field: "path")
        self.path = path
        self.blobSHA = blobSHA
        self.content = content
    }

    private enum CodingKeys: String, CodingKey { case path, blobSHA, content }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            path: container.decode(String.self, forKey: .path),
            blobSHA: container.decode(String.self, forKey: .blobSHA),
            content: container.decode(String.self, forKey: .content)
        )
    }
}

public struct GitSnapshot: Sendable, Codable, Equatable {
    public let headCommitSHA: String
    public let rootTreeSHA: String
    public let files: [RemoteFile]

    public init(headCommitSHA: String, rootTreeSHA: String, files: [RemoteFile]) throws {
        guard !headCommitSHA.isEmpty, !rootTreeSHA.isEmpty else {
            throw OTodoError.validation(field: "snapshot", message: "Commit and root tree SHAs are required")
        }
        guard Set(files.map(\.path)).count == files.count else {
            throw OTodoError.validation(field: "snapshot.files", message: "Remote file paths must be unique")
        }
        self.headCommitSHA = headCommitSHA
        self.rootTreeSHA = rootTreeSHA
        self.files = files
    }

    private enum CodingKeys: String, CodingKey { case headCommitSHA, rootTreeSHA, files }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            headCommitSHA: container.decode(String.self, forKey: .headCommitSHA),
            rootTreeSHA: container.decode(String.self, forKey: .rootTreeSHA),
            files: container.decode([RemoteFile].self, forKey: .files)
        )
    }
}

public struct PendingChange: Sendable, Codable, Equatable {
    public let id: UUID
    public let path: String
    public let baseBlobSHA: String?
    public let content: String
    public let createdAt: Date

    public init(id: UUID, path: String, baseBlobSHA: String?, content: String, createdAt: Date) throws {
        try DomainValidation.validateRelativePath(path, field: "path")
        self.id = id
        self.path = path
        self.baseBlobSHA = baseBlobSHA
        self.content = content
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, path, baseBlobSHA, content, createdAt }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            path: container.decode(String.self, forKey: .path),
            baseBlobSHA: container.decodeIfPresent(String.self, forKey: .baseBlobSHA),
            content: container.decode(String.self, forKey: .content),
            createdAt: container.decode(Date.self, forKey: .createdAt)
        )
    }
}

public struct SyncConflict: Sendable, Codable, Equatable {
    public let path: String
    public let baseBlobSHA: String?
    public let remoteBlobSHA: String?
    public let localContent: String
    public let remoteContent: String?

    public init(
        path: String,
        baseBlobSHA: String?,
        remoteBlobSHA: String?,
        localContent: String,
        remoteContent: String?
    ) throws {
        try DomainValidation.validateRelativePath(path, field: "path")
        self.path = path
        self.baseBlobSHA = baseBlobSHA
        self.remoteBlobSHA = remoteBlobSHA
        self.localContent = localContent
        self.remoteContent = remoteContent
    }

    private enum CodingKeys: String, CodingKey {
        case path, baseBlobSHA, remoteBlobSHA, localContent, remoteContent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            path: container.decode(String.self, forKey: .path),
            baseBlobSHA: container.decodeIfPresent(String.self, forKey: .baseBlobSHA),
            remoteBlobSHA: container.decodeIfPresent(String.self, forKey: .remoteBlobSHA),
            localContent: container.decode(String.self, forKey: .localContent),
            remoteContent: container.decodeIfPresent(String.self, forKey: .remoteContent)
        )
    }
}

public struct SyncReport: Sendable, Codable, Equatable {
    public let pulledCount: Int
    public let pushedCount: Int
    public let conflicts: [SyncConflict]

    public init(pulledCount: Int, pushedCount: Int, conflicts: [SyncConflict]) throws {
        guard pulledCount >= 0, pushedCount >= 0 else {
            throw OTodoError.validation(field: "syncReport", message: "Sync counts cannot be negative")
        }
        self.pulledCount = pulledCount
        self.pushedCount = pushedCount
        self.conflicts = conflicts
    }

    private enum CodingKeys: String, CodingKey {
        case pulledCount, pushedCount, conflicts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            pulledCount: container.decode(Int.self, forKey: .pulledCount),
            pushedCount: container.decode(Int.self, forKey: .pushedCount),
            conflicts: container.decode([SyncConflict].self, forKey: .conflicts)
        )
    }
}

public struct TaskDocument: Sendable, Codable, Equatable {
    public let task: TodoTask
    public let content: String
    public let blobSHA: String?

    public init(task: TodoTask, content: String, blobSHA: String?) {
        self.task = task
        self.content = content
        self.blobSHA = blobSHA
    }
}

public struct WorkspaceState: Sendable, Codable, Equatable {
    public let selection: RepositorySelection
    public let configuration: StoreConfiguration
    public let knownProjectSlugs: [String]
    public let tasks: [TaskDocument]
    public let baseHeadCommitSHA: String
    public let baseRootTreeSHA: String
    public let pendingChanges: [PendingChange]
    public let conflicts: [SyncConflict]
    public let revision: UInt64

    public init(
        selection: RepositorySelection,
        configuration: StoreConfiguration,
        knownProjectSlugs: [String] = [],
        tasks: [TaskDocument],
        baseHeadCommitSHA: String,
        baseRootTreeSHA: String,
        pendingChanges: [PendingChange],
        conflicts: [SyncConflict],
        revision: UInt64 = 0
    ) throws {
        guard !baseHeadCommitSHA.isEmpty, !baseRootTreeSHA.isEmpty else {
            throw OTodoError.validation(field: "workspace", message: "Base commit and tree SHAs are required")
        }
        guard Set(tasks.map { $0.task.relativePath }).count == tasks.count else {
            throw OTodoError.validation(field: "workspace.tasks", message: "Task paths must be unique")
        }
        guard Set(tasks.map(\.task.id)).count == tasks.count else {
            throw OTodoError.validation(field: "workspace.tasks", message: "Task IDs must be unique")
        }
        guard Set(knownProjectSlugs).count == knownProjectSlugs.count else {
            throw OTodoError.validation(
                field: "workspace.knownProjectSlugs",
                message: "Known project slugs must be unique"
            )
        }
        try DomainValidation.validateProjectSlugs(knownProjectSlugs)
        guard Set(pendingChanges.map(\.path)).count == pendingChanges.count else {
            throw OTodoError.corruptLocalState(message: "More than one pending change exists for a path")
        }
        guard Set(conflicts.map(\.path)).count == conflicts.count else {
            throw OTodoError.corruptLocalState(message: "More than one conflict exists for a path")
        }
        self.selection = selection
        self.configuration = configuration
        self.tasks = tasks
        self.knownProjectSlugs = knownProjectSlugs
        self.baseHeadCommitSHA = baseHeadCommitSHA
        self.baseRootTreeSHA = baseRootTreeSHA
        self.pendingChanges = pendingChanges
        self.conflicts = conflicts
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case selection, configuration, tasks, knownProjectSlugs, baseHeadCommitSHA, baseRootTreeSHA
        case pendingChanges, conflicts, revision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            selection: container.decode(RepositorySelection.self, forKey: .selection),
            configuration: container.decode(StoreConfiguration.self, forKey: .configuration),
            knownProjectSlugs: container.decodeIfPresent(
                [String].self,
                forKey: .knownProjectSlugs
            ) ?? [],
            tasks: container.decode([TaskDocument].self, forKey: .tasks),
            baseHeadCommitSHA: container.decode(String.self, forKey: .baseHeadCommitSHA),
            baseRootTreeSHA: container.decode(String.self, forKey: .baseRootTreeSHA),
            pendingChanges: container.decode([PendingChange].self, forKey: .pendingChanges),
            conflicts: container.decode([SyncConflict].self, forKey: .conflicts),
            revision: container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        )
    }
}

public struct RemoteChange: Sendable, Codable, Equatable {
    public let path: String
    /// UTF-8 file content, or `nil` to delete the path.
    public let content: String?

    public init(path: String, content: String?) throws {
        try DomainValidation.validateRelativePath(path, field: "path")
        self.path = path
        self.content = content
    }

    private enum CodingKeys: String, CodingKey { case path, content }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            path: container.decode(String.self, forKey: .path),
            content: container.decodeIfPresent(String.self, forKey: .content)
        )
    }
}

private enum DomainValidation {
    private static let coreProperties: Set<String> = [
        "id", "name", "state", "projects", "tags", "due_date", "recurrence",
        "recurrence_from", "last_completed_date",
    ]

    static func validateRelativePath(_ path: String, field: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw OTodoError.validation(field: field, message: "Expected a normalized relative POSIX path")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw OTodoError.validation(field: field, message: "Path cannot contain empty, . or .. components")
        }
    }

    static func validateManagedDirectory(_ path: String, field: String) throws {
        try validateRelativePath(path, field: field)
        guard path.split(separator: "/").first != ".todo" else {
            throw OTodoError.validation(field: field, message: "Managed directories cannot overlap .todo")
        }
    }

    static func validateStateID(_ id: String, field: String) throws {
        let bytes = Array(id.utf8)
        guard let first = bytes.first,
              (97 ... 122).contains(first) || (48 ... 57).contains(first),
              bytes.dropFirst().allSatisfy({
                  (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 95 || $0 == 45
              })
        else {
            throw OTodoError.validation(
                field: field,
                message: "Expected a lowercase ASCII slug matching [a-z0-9][a-z0-9_-]*"
            )
        }
    }

    static func validateProjectSlugs(_ slugs: [String]) throws {
        guard Set(slugs).count == slugs.count else {
            throw OTodoError.validation(field: "projects", message: "Project slugs must be unique")
        }
        for slug in slugs {
            let bytes = Array(slug.utf8)
            guard let first = bytes.first,
                  (97 ... 122).contains(first) || (48 ... 57).contains(first),
                  bytes.dropFirst().allSatisfy({
                      (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45
                  })
            else {
                throw OTodoError.validation(
                    field: "projects",
                    message: "Project slugs must match [a-z0-9][a-z0-9-]*"
                )
            }
        }
    }

    static func validateTags(_ tags: [String]) throws {
        guard Set(tags).count == tags.count else {
            throw OTodoError.validation(field: "tags", message: "Tags must be unique")
        }
        for tag in tags {
            let invalid = tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || tag.hasPrefix("#")
                || tag.contains(",")
                || tag.contains(where: { "[]{}".contains($0) })
                || tag.unicodeScalars.contains(where: {
                    CharacterSet.whitespacesAndNewlines.contains($0)
                        || CharacterSet.controlCharacters.contains($0)
                })
            guard !invalid else {
                throw OTodoError.validation(field: "tags", message: "Tag contains unsupported characters")
            }
        }
    }

    static func validateRecurrence(
        recurrence: String?,
        recurrenceFrom: RecurrenceFrom?,
        dueDate: CivilDate?,
        lastCompletedDate: CivilDate?
    ) throws {
        if let recurrence {
            guard !recurrence.isEmpty else {
                throw OTodoError.validation(field: "recurrence", message: "Recurrence rule must not be empty")
            }
            guard dueDate != nil else {
                throw OTodoError.validation(field: "dueDate", message: "Recurring tasks require a due date")
            }
            guard recurrenceFrom != nil else {
                throw OTodoError.validation(
                    field: "recurrenceFrom",
                    message: "Recurring tasks require a recurrence origin"
                )
            }
        } else if recurrenceFrom != nil || lastCompletedDate != nil {
            throw OTodoError.validation(
                field: "recurrence",
                message: "Recurrence origin and completion date require a recurrence rule"
            )
        }
    }

    static func validateExtraProperties(_ properties: [YAMLProperty]) throws {
        let names = properties.map(\.name)
        guard names.allSatisfy({ !$0.isEmpty }) else {
            throw OTodoError.validation(field: "extraProperties", message: "Property names must not be empty")
        }
        guard Set(names).count == names.count else {
            throw OTodoError.validation(field: "extraProperties", message: "Property names must be unique")
        }
        guard Set(names).isDisjoint(with: coreProperties) else {
            throw OTodoError.validation(
                field: "extraProperties",
                message: "Core task properties cannot also appear as extra properties"
            )
        }
    }
}
