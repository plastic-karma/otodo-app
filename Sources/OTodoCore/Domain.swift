import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

public struct CivilTime: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) throws {
        let bytes = Array(rawValue.utf8)
        guard bytes.count == 5,
              bytes[2] == 58,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 2 || (48 ... 57).contains(byte)
              })
        else {
            throw OTodoError.validation(field: "time", message: "Expected HH:mm")
        }

        let hour = Int(bytes[0] - 48) * 10 + Int(bytes[1] - 48)
        let minute = Int(bytes[3] - 48) * 10 + Int(bytes[4] - 48)
        guard (0 ... 23).contains(hour), (0 ... 59).contains(minute) else {
            throw OTodoError.validation(
                field: "time",
                message: "Expected a 24-hour time from 00:00 through 23:59"
            )
        }
        self.rawValue = rawValue
    }

    public var hour: Int {
        Int(rawValue.prefix(2))!
    }

    public var minute: Int {
        Int(rawValue.suffix(2))!
    }

    public var description: String { rawValue }

    public static func < (lhs: CivilTime, rhs: CivilTime) -> Bool {
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
}

public struct WorkflowState: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let isTerminal: Bool

    public static let inProgress = try! WorkflowState(id: "in-progress", name: "In Progress", isTerminal: false)

    public var isInProgress: Bool { id == Self.inProgress.id && !isTerminal }

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
    public static let supportedSchemaVersion = 2
    public static let supportedSchemaVersions: Set<Int> = [1, 2]

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
        guard Self.supportedSchemaVersions.contains(schemaVersion) else {
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
    public var dueTime: CivilTime?
    public var recurrence: String?
    public var recurrenceFrom: RecurrenceFrom?
    public var lastCompletedDate: CivilDate?
    public var body: String
    public var extraProperties: [YAMLProperty]
    public var parentID: TaskID?
    public var url: String?

    public init(
        id: TaskID,
        relativePath: String,
        name: String,
        state: String,
        projectSlugs: [String],
        tags: [String],
        dueDate: CivilDate?,
        dueTime: CivilTime? = nil,
        recurrence: String?,
        recurrenceFrom: RecurrenceFrom?,
        lastCompletedDate: CivilDate?,
        body: String,
        extraProperties: [YAMLProperty],
        parentID: TaskID? = nil,
        url: String? = nil
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
        guard dueTime == nil || dueDate != nil else {
            throw OTodoError.validation(
                field: "dueTime",
                message: "A due time requires a due date"
            )
        }
        try DomainValidation.validateRecurrence(
            recurrence: recurrence,
            recurrenceFrom: recurrenceFrom,
            dueDate: dueDate,
            lastCompletedDate: lastCompletedDate
        )
        try DomainValidation.validateExtraProperties(extraProperties)
        try DomainValidation.validateURL(url)
        guard parentID == nil || !extraProperties.contains(where: { $0.name == "parent" }) else {
            throw OTodoError.validation(field: "parent", message: "Typed parent and extra parent metadata cannot coexist")
        }

        self.id = id
        self.relativePath = relativePath
        self.name = name
        self.state = state
        self.projectSlugs = projectSlugs
        self.tags = tags
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.recurrence = recurrence
        self.recurrenceFrom = recurrenceFrom
        self.lastCompletedDate = lastCompletedDate
        self.body = body
        self.extraProperties = extraProperties
        self.parentID = parentID
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case id, relativePath, name, state, projectSlugs, tags, dueDate, dueTime, recurrence
        case recurrenceFrom, lastCompletedDate, body, extraProperties, parentID, url
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var extras = try container.decode([YAMLProperty].self, forKey: .extraProperties)
        var url = try container.decodeIfPresent(String.self, forKey: .url)
        // Older caches stored this additive frontmatter field as plugin metadata.
        if let index = extras.firstIndex(where: { $0.name == "url" }) {
            guard !extras.dropFirst(index + 1).contains(where: { $0.name == "url" }) else {
                throw OTodoError.validation(field: "url", message: "Duplicate URL metadata")
            }
            let legacy = extras.remove(at: index)
            let legacyURL: String?
            switch legacy.value {
            case let .string(value): legacyURL = value
            case .null: legacyURL = nil
            default: throw OTodoError.validation(field: "url", message: "URL must be a string")
            }
            guard url == nil || legacyURL == nil || url == legacyURL else {
                throw OTodoError.validation(field: "url", message: "Conflicting URL metadata")
            }
            url = url ?? legacyURL
        }
        try self.init(
            id: container.decode(TaskID.self, forKey: .id),
            relativePath: container.decode(String.self, forKey: .relativePath),
            name: container.decode(String.self, forKey: .name),
            state: container.decode(String.self, forKey: .state),
            projectSlugs: container.decode([String].self, forKey: .projectSlugs),
            tags: container.decode([String].self, forKey: .tags),
            dueDate: container.decodeIfPresent(CivilDate.self, forKey: .dueDate),
            dueTime: container.decodeIfPresent(CivilTime.self, forKey: .dueTime),
            recurrence: container.decodeIfPresent(String.self, forKey: .recurrence),
            recurrenceFrom: container.decodeIfPresent(RecurrenceFrom.self, forKey: .recurrenceFrom),
            lastCompletedDate: container.decodeIfPresent(CivilDate.self, forKey: .lastCompletedDate),
            body: container.decode(String.self, forKey: .body),
            extraProperties: extras,
            parentID: container.decodeIfPresent(TaskID.self, forKey: .parentID),
            url: url
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
    public let attachments: [AttachmentMetadata]

    public init(headCommitSHA: String, rootTreeSHA: String, files: [RemoteFile], attachments: [AttachmentMetadata] = []) throws {
        guard !headCommitSHA.isEmpty, !rootTreeSHA.isEmpty else {
            throw OTodoError.validation(field: "snapshot", message: "Commit and root tree SHAs are required")
        }
        guard Set(files.map(\.path)).count == files.count else {
            throw OTodoError.validation(field: "snapshot.files", message: "Remote file paths must be unique")
        }
        self.headCommitSHA = headCommitSHA
        self.rootTreeSHA = rootTreeSHA
        self.files = files
        guard Set(attachments.map(\.path)).count == attachments.count else {
            throw OTodoError.validation(field: "attachments", message: "Attachment paths must be unique")
        }
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey { case headCommitSHA, rootTreeSHA, files, attachments }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            headCommitSHA: container.decode(String.self, forKey: .headCommitSHA),
            rootTreeSHA: container.decode(String.self, forKey: .rootTreeSHA),
            files: container.decode([RemoteFile].self, forKey: .files),
            attachments: container.decodeIfPresent([AttachmentMetadata].self, forKey: .attachments) ?? []
        )
    }
}

/// Explicit payloads prevent binary imports from ever being interpreted as deletions.
public enum ChangePayload: Sendable, Codable, Equatable {
    case text(String)
    case binaryFile(BinaryFileReference)
    case remoteBinary(AttachmentMetadata)
    case deletion

    public var text: String? { if case let .text(value) = self { value } else { nil } }
    public var binaryFile: BinaryFileReference? { if case let .binaryFile(value) = self { value } else { nil } }
}

public struct PendingChange: Sendable, Codable, Equatable {
    public let id: UUID
    public let path: String
    public let baseBlobSHA: String?
    public let payload: ChangePayload
    public var content: String? { payload.text }
    public let createdAt: Date

    public init(id: UUID, path: String, baseBlobSHA: String?, content: String?, createdAt: Date) throws {
        try self.init(id: id, path: path, baseBlobSHA: baseBlobSHA,
                      payload: content.map(ChangePayload.text) ?? .deletion, createdAt: createdAt)
    }

    public init(id: UUID, path: String, baseBlobSHA: String?, payload: ChangePayload, createdAt: Date) throws {
        try DomainValidation.validateRelativePath(path, field: "path")
        self.id = id
        self.path = path
        self.baseBlobSHA = baseBlobSHA
        if case .remoteBinary = payload { throw OTodoError.corruptLocalState(message: "An outbox upload requires local binary bytes") }
        self.payload = payload
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, path, baseBlobSHA, content, payload, createdAt }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let payload = try container.decodeIfPresent(ChangePayload.self, forKey: .payload)
            ?? container.decodeIfPresent(String.self, forKey: .content).map(ChangePayload.text) ?? .deletion
        try self.init(id: container.decode(UUID.self, forKey: .id), path: container.decode(String.self, forKey: .path),
                      baseBlobSHA: container.decodeIfPresent(String.self, forKey: .baseBlobSHA), payload: payload,
                      createdAt: container.decode(Date.self, forKey: .createdAt))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(baseBlobSHA, forKey: .baseBlobSHA)
        try container.encode(payload, forKey: .payload)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

public struct SyncConflict: Sendable, Codable, Equatable {
    public let path: String
    public let baseBlobSHA: String?
    public let remoteBlobSHA: String?
    public let localPayload: ChangePayload
    public let remotePayload: ChangePayload
    public var localContent: String? { localPayload.text }
    public var remoteContent: String? { remotePayload.text }

    public init(path: String, baseBlobSHA: String?, remoteBlobSHA: String?, localContent: String?, remoteContent: String?) throws {
        try self.init(path: path, baseBlobSHA: baseBlobSHA, remoteBlobSHA: remoteBlobSHA,
                      localPayload: localContent.map(ChangePayload.text) ?? .deletion,
                      remotePayload: remoteContent.map(ChangePayload.text) ?? .deletion)
    }
    public init(path: String, baseBlobSHA: String?, remoteBlobSHA: String?, localPayload: ChangePayload, remotePayload: ChangePayload) throws {
        try DomainValidation.validateRelativePath(path, field: "path")
        self.path = path
        self.baseBlobSHA = baseBlobSHA
        self.remoteBlobSHA = remoteBlobSHA
        self.localPayload = localPayload
        self.remotePayload = remotePayload
    }
    private enum CodingKeys: String, CodingKey {
        case path, baseBlobSHA, remoteBlobSHA, localContent, remoteContent, localPayload, remotePayload
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(path: container.decode(String.self, forKey: .path),
                      baseBlobSHA: container.decodeIfPresent(String.self, forKey: .baseBlobSHA),
                      remoteBlobSHA: container.decodeIfPresent(String.self, forKey: .remoteBlobSHA),
                      localPayload: container.decodeIfPresent(ChangePayload.self, forKey: .localPayload)
                        ?? container.decodeIfPresent(String.self, forKey: .localContent).map(ChangePayload.text) ?? .deletion,
                      remotePayload: container.decodeIfPresent(ChangePayload.self, forKey: .remotePayload)
                        ?? container.decodeIfPresent(String.self, forKey: .remoteContent).map(ChangePayload.text) ?? .deletion)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(baseBlobSHA, forKey: .baseBlobSHA)
        try container.encodeIfPresent(remoteBlobSHA, forKey: .remoteBlobSHA)
        try container.encode(localPayload, forKey: .localPayload)
        try container.encode(remotePayload, forKey: .remotePayload)
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
    public let relationshipBlocks: [TaskRelationshipBlock]
    public let attachments: [AttachmentMetadata]

    public init(
        selection: RepositorySelection,
        configuration: StoreConfiguration,
        knownProjectSlugs: [String] = [],
        tasks: [TaskDocument],
        baseHeadCommitSHA: String,
        baseRootTreeSHA: String,
        pendingChanges: [PendingChange],
        conflicts: [SyncConflict],
        revision: UInt64 = 0,
        relationshipBlocks: [TaskRelationshipBlock] = [],
        attachments: [AttachmentMetadata] = []
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
        self.relationshipBlocks = relationshipBlocks
        guard Set(attachments.map(\.path)).count == attachments.count else {
            throw OTodoError.corruptLocalState(message: "Attachment paths must be unique")
        }
        let prefix = selection.storePath.isEmpty ? "Attachments/" : selection.storePath + "/Attachments/"
        for pending in pendingChanges where pending.payload.binaryFile != nil {
            guard pending.path.hasPrefix(prefix) else { throw OTodoError.corruptLocalState(message: "Binary outbox path is outside selected Attachments/") }
        }
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case selection, configuration, tasks, knownProjectSlugs, baseHeadCommitSHA, baseRootTreeSHA
        case pendingChanges, conflicts, revision, relationshipBlocks, attachments
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
            revision: container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0,
            relationshipBlocks: container.decodeIfPresent([TaskRelationshipBlock].self, forKey: .relationshipBlocks) ?? [],
            attachments: container.decodeIfPresent([AttachmentMetadata].self, forKey: .attachments) ?? []
        )
    }
}

public struct RemoteChange: Sendable, Codable, Equatable {
    public let path: String
    public let content: String?
    public let binaryContent: Data?

    public init(path: String, content: String?, binaryContent: Data? = nil) throws {
        try DomainValidation.validateRelativePath(path, field: "path")
        self.path = path
        guard content == nil || binaryContent == nil else {
            throw OTodoError.validation(field: "payload", message: "A file cannot have both text and binary payloads")
        }
        self.content = content
        self.binaryContent = binaryContent
    }

    private enum CodingKeys: String, CodingKey { case path, content, binaryContent }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            path: container.decode(String.self, forKey: .path),
            content: container.decodeIfPresent(String.self, forKey: .content),
            binaryContent: container.decodeIfPresent(Data.self, forKey: .binaryContent)
        )
    }
}

public enum DomainValidation {
    private static let coreProperties: Set<String> = [
        "id", "name", "state", "projects", "tags", "due_date", "due_time", "recurrence",
        "recurrence_from", "last_completed_date", "url",
    ]

    public static func validateURL(_ value: String?) throws {
        guard let value else { return }
        let invalid = OTodoError.validation(field: "url", message: "Expected an absolute HTTP or HTTPS URL with a host")
        guard !value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }), !value.contains(where: { "\\<>\"{}|^`".contains($0) }),
        value.range(of: "%(?![0-9A-Fa-f]{2})", options: .regularExpression) == nil,
        let separator = value.range(of: "://"),
        ["http", "https"].contains(value[..<separator.lowerBound].lowercased()),
        let components = URLComponents(string: value),
        let host = components.host, !host.isEmpty,
        components.url != nil else { throw invalid }
        let authority = value[separator.upperBound...].prefix { !"/?#".contains($0) }
        let authorityParts = authority.split(separator: "@", omittingEmptySubsequences: false)
        guard authorityParts.count <= 2,
              authorityParts.count == 1 || !authorityParts[0].contains(where: { "[]".contains($0) })
        else { throw invalid }
        let hostPort = authorityParts.last ?? ""
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { throw invalid }
            let addressText = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            var address = in6_addr()
            guard addressText.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { throw invalid }
            let suffix = hostPort[hostPort.index(after: close)...]
            guard suffix.isEmpty || suffix.hasPrefix(":") else { throw invalid }
        } else {
            guard !hostPort.contains(where: { "[]".contains($0) }),
                  let rawHost = hostPort.split(separator: ":", omittingEmptySubsequences: false).first,
                  let decodedHost = String(rawHost).removingPercentEncoding,
                  !decodedHost.isEmpty,
                  decodedHost.unicodeScalars.allSatisfy({
                      if $0.value > 127 {
                          return !CharacterSet.whitespacesAndNewlines.contains($0)
                              && !CharacterSet.controlCharacters.contains($0)
                      }
                      return CharacterSet.alphanumerics.contains($0) || "-._~!$&'()*+,;=%".unicodeScalars.contains($0)
                  })
            else { throw invalid }
        }
        if let colon = hostPort.lastIndex(of: ":"), !hostPort.hasSuffix("]") {
            let rawPort = hostPort[hostPort.index(after: colon)...]
            guard !rawPort.isEmpty, rawPort.utf8.allSatisfy({ (48...57).contains($0) }),
                  let port = Int(rawPort), (0...65535).contains(port) else { throw invalid }
        }
    }

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
