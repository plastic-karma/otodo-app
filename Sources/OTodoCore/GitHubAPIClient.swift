import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GitHubResourceBudget: Sendable, Equatable {
    let maximumFallbackTreeRequests: Int
    let maximumTreeDepth: Int
    let maximumTreeEntries: Int
    let maximumSelectedFiles: Int
    let maximumRecordBytes: Int
    let maximumConfigurationBytes: Int
    let maximumAggregateBlobBytes: Int

    static let production = GitHubResourceBudget(
        maximumFallbackTreeRequests: 512,
        maximumTreeDepth: 64,
        maximumTreeEntries: 100_000,
        maximumSelectedFiles: 10_000,
        maximumRecordBytes: 8 * 1_024 * 1_024,
        maximumConfigurationBytes: 1 * 1_024 * 1_024,
        maximumAggregateBlobBytes: 64 * 1_024 * 1_024
    )
}

public actor GitHubAPIClient: GitHubServing {
    private let transport: any HTTPTransport
    private let baseURL: URL
    private let configurationCodec: any StoreConfigCoding
    private var accessToken: String
    private let resourceBudget: GitHubResourceBudget

    public init(
        accessToken: String,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        baseURL: URL = URL(string: "https://api.github.com")!,
        configurationCodec: any StoreConfigCoding = StrictStoreConfigCodec()
    ) {
        self.accessToken = accessToken
        self.transport = transport
        self.baseURL = baseURL
        self.configurationCodec = configurationCodec
        self.resourceBudget = .production
    }

    init(
        accessToken: String,
        transport: any HTTPTransport,
        baseURL: URL = URL(string: "https://api.github.com")!,
        configurationCodec: any StoreConfigCoding = StrictStoreConfigCodec(),
        resourceBudget: GitHubResourceBudget
    ) {
        precondition(
            resourceBudget.maximumFallbackTreeRequests >= 0
                && resourceBudget.maximumTreeDepth >= 0
                && resourceBudget.maximumTreeEntries >= 0
                && resourceBudget.maximumSelectedFiles >= 0
                && resourceBudget.maximumRecordBytes >= 0
                && resourceBudget.maximumConfigurationBytes >= 0
                && resourceBudget.maximumAggregateBlobBytes >= 0,
            "GitHub resource limits cannot be negative"
        )
        self.accessToken = accessToken
        self.transport = transport
        self.baseURL = baseURL
        self.configurationCodec = configurationCodec
        self.resourceBudget = resourceBudget
    }

    /// Replaces the OAuth access token used by subsequent requests without rebuilding the client.
    public func updateAccessToken(_ accessToken: String) {
        self.accessToken = accessToken
    }

    public func updateToken(_ token: OAuthTokenPair) {
        accessToken = token.accessToken
    }

    public func listRepositories() async throws -> [RepositorySummary] {
        var repositories: [RepositorySummary] = []
        var page = 1

        while true {
            let response = try await request(
                method: "GET",
                path: "user/repos",
                queryItems: [
                    URLQueryItem(name: "visibility", value: "all"),
                    URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
                    URLQueryItem(name: "sort", value: "full_name"),
                    URLQueryItem(name: "direction", value: "asc"),
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: String(page)),
                ]
            )
            try validate(response, context: "listing repositories", notFoundResource: "authenticated GitHub repositories")
            let wire: [GitHubRepositoryDTO] = try decode(response, context: "listing repositories")
            repositories.append(contentsOf: wire.map {
                RepositorySummary(
                    owner: $0.owner.login,
                    name: $0.name,
                    defaultBranch: $0.defaultBranch,
                    isPrivate: $0.isPrivate
                )
            })

            if wire.count < 100 { break }
            page += 1
        }

        return repositories
    }

    public func discoverStorePaths(
        repository: RepositorySummary,
        branch: String
    ) async throws -> [String] {
        let state = try await fetchBranchState(owner: repository.owner, repository: repository.name, branch: branch)
        let entries = try await recursivelyListTree(
            owner: repository.owner,
            repository: repository.name,
            treeSHA: state.rootTreeSHA,
            context: "discovering todo stores"
        )

        var stores = Set<String>()
        for entry in entries where entry.type == "blob" {
            if entry.path == ".todo/config.toml" {
                stores.insert("")
            } else if entry.path.hasSuffix("/.todo/config.toml") {
                stores.insert(String(entry.path.dropLast("/.todo/config.toml".count)))
            }
        }
        return stores.sorted()
    }

    public func fetchSnapshot(selection: RepositorySelection) async throws -> GitSnapshot {
        let state = try await fetchBranchState(
            owner: selection.owner,
            repository: selection.name,
            branch: selection.branch
        )
        let storeTreeSHA = try await resolveTree(
            owner: selection.owner,
            repository: selection.name,
            rootTreeSHA: state.rootTreeSHA,
            path: selection.storePath
        )
        let entries = try await recursivelyListTree(
            owner: selection.owner,
            repository: selection.name,
            treeSHA: storeTreeSHA,
            context: "cataloguing todo store \(displayStorePath(selection.storePath))"
        )

        guard let configEntry = entries.first(where: {
            $0.type == "blob" && $0.path == ".todo/config.toml"
        }) else {
            throw OTodoError.notFound(resource: "\(displayStorePath(selection.storePath))/.todo/config.toml")
        }
        try validateKnownBlobSize(
            configEntry,
            maximumBytes: resourceBudget.maximumConfigurationBytes,
            resource: "configuration"
        )

        let configBlob = try await fetchBlobText(
            owner: selection.owner,
            repository: selection.name,
            sha: configEntry.sha,
            context: "reading todo store configuration",
            maximumBytes: resourceBudget.maximumConfigurationBytes,
            limitName: "configuration"
        )
        guard configBlob.byteCount <= resourceBudget.maximumAggregateBlobBytes else {
            throw resourceLimit("aggregate decoded snapshot content exceeded \(resourceBudget.maximumAggregateBlobBytes) bytes")
        }
        let configuration = try configurationCodec.parseConfiguration(configBlob.text)

        let selectedEntries = entries.filter { entry in
            guard entry.type == "blob" else { return false }
            if entry.path == ".todo/config.toml" {
                return true
            }
            return isMarkdown(entry.path, inside: configuration.tasksDirectory)
                || isMarkdown(entry.path, inside: configuration.projectsDirectory)
        }.sorted { $0.path < $1.path }
        guard selectedEntries.count <= resourceBudget.maximumSelectedFiles else {
            throw resourceLimit("selected file count exceeded \(resourceBudget.maximumSelectedFiles)")
        }

        var knownTotal = configBlob.byteCount
        for entry in selectedEntries where entry.path != ".todo/config.toml" {
            try validateKnownBlobSize(
                entry,
                maximumBytes: resourceBudget.maximumRecordBytes,
                resource: "task/project record \(entry.path)"
            )
            if let size = entry.size {
                guard knownTotal <= resourceBudget.maximumAggregateBlobBytes - size else {
                    throw resourceLimit("aggregate decoded snapshot content exceeded \(resourceBudget.maximumAggregateBlobBytes) bytes")
                }
                knownTotal += size
            }
        }

        var retainedBytes = configBlob.byteCount
        var files: [RemoteFile] = []
        files.reserveCapacity(selectedEntries.count)
        for entry in selectedEntries {
            let content: String
            if entry.path == ".todo/config.toml" {
                content = configBlob.text
            } else {
                let remaining = resourceBudget.maximumAggregateBlobBytes - retainedBytes
                let maximumBytes = min(resourceBudget.maximumRecordBytes, remaining)
                let limitName = remaining < resourceBudget.maximumRecordBytes
                    ? "aggregate decoded snapshot content"
                    : "task/project record"
                let blob = try await fetchBlobText(
                    owner: selection.owner,
                    repository: selection.name,
                    sha: entry.sha,
                    context: "reading \(joinedPath(selection.storePath, entry.path))",
                    maximumBytes: maximumBytes,
                    limitName: limitName
                )
                retainedBytes += blob.byteCount
                content = blob.text
            }
            files.append(try RemoteFile(
                path: joinedPath(selection.storePath, entry.path),
                blobSHA: entry.sha,
                content: content
            ))
        }

        return try GitSnapshot(
            headCommitSHA: state.headCommitSHA,
            rootTreeSHA: state.rootTreeSHA,
            files: files
        )
    }

    public func commit(
        selection: RepositorySelection,
        changes: [RemoteChange],
        against snapshot: GitSnapshot,
        message: String
    ) async throws -> String {
        guard !changes.isEmpty else {
            throw OTodoError.validation(field: "changes", message: "At least one repository change is required")
        }
        guard !message.isEmpty else {
            throw OTodoError.validation(field: "message", message: "Commit message must not be empty")
        }
        guard Set(changes.map(\.path)).count == changes.count else {
            throw OTodoError.validation(field: "changes", message: "Repository change paths must be unique")
        }

        var treeEntries: [GitHubCreateTreeEntryDTO] = []
        treeEntries.reserveCapacity(changes.count)
        for change in changes {
            guard isPath(change.path, insideStore: selection.storePath) else {
                throw OTodoError.validation(
                    field: "changes.path",
                    message: "\(change.path) is outside selected store \(displayStorePath(selection.storePath))"
                )
            }

            if let content = change.content {
                let blobRequest = GitHubCreateBlobRequestDTO(content: content)
                let response = try await request(
                    method: "POST",
                    path: try repositoryPath(selection.owner, selection.name, suffix: "git/blobs"),
                    body: try encode(blobRequest)
                )
                try validate(response, context: "creating blob for \(change.path)")
                let blob: GitHubCreatedObjectDTO = try decode(response, context: "creating blob for \(change.path)")
                guard !blob.sha.isEmpty else {
                    throw OTodoError.transport(statusCode: response.statusCode, message: "GitHub returned an empty blob SHA for \(change.path)")
                }
                treeEntries.append(GitHubCreateTreeEntryDTO(path: change.path, sha: blob.sha))
            } else {
                treeEntries.append(GitHubCreateTreeEntryDTO(path: change.path, sha: nil))
            }
        }

        let treeRequest = GitHubCreateTreeRequestDTO(baseTree: snapshot.rootTreeSHA, tree: treeEntries)
        let treeResponse = try await request(
            method: "POST",
            path: try repositoryPath(selection.owner, selection.name, suffix: "git/trees"),
            body: try encode(treeRequest)
        )
        try validate(treeResponse, context: "creating repository tree")
        let tree: GitHubCreatedObjectDTO = try decode(treeResponse, context: "creating repository tree")
        guard !tree.sha.isEmpty else {
            throw OTodoError.transport(statusCode: treeResponse.statusCode, message: "GitHub returned an empty tree SHA")
        }

        let commitRequest = GitHubCreateCommitRequestDTO(
            message: message,
            tree: tree.sha,
            parents: [snapshot.headCommitSHA]
        )
        let commitResponse = try await request(
            method: "POST",
            path: try repositoryPath(selection.owner, selection.name, suffix: "git/commits"),
            body: try encode(commitRequest)
        )
        try validate(commitResponse, context: "creating repository commit")
        let commit: GitHubCreatedObjectDTO = try decode(commitResponse, context: "creating repository commit")
        guard !commit.sha.isEmpty else {
            throw OTodoError.transport(statusCode: commitResponse.statusCode, message: "GitHub returned an empty commit SHA")
        }
        return commit.sha
    }

    public func updateReference(
        selection: RepositorySelection,
        to commitSHA: String,
        expectedHead: String
    ) async throws {
        guard !commitSHA.isEmpty, !expectedHead.isEmpty else {
            throw OTodoError.validation(field: "reference", message: "Commit and expected-head SHAs are required")
        }

        let current = try await fetchReferenceSHA(
            owner: selection.owner,
            repository: selection.name,
            branch: selection.branch
        )
        guard current == expectedHead else {
            throw OTodoError.conflict(
                message: "Branch \(selection.branch) moved from expected head \(expectedHead) to \(current)"
            )
        }

        let response = try await request(
            method: "PATCH",
            path: try repositoryPath(
                selection.owner,
                selection.name,
                suffix: "git/refs/heads/\(percentEncodePathSegment(selection.branch))"
            ),
            body: try encode(GitHubUpdateReferenceRequestDTO(sha: commitSHA))
        )
        if response.statusCode == 409 || response.statusCode == 422 {
            let latest = try await fetchReferenceSHA(
                owner: selection.owner,
                repository: selection.name,
                branch: selection.branch
            )
            if latest != expectedHead {
                throw OTodoError.conflict(
                    message: "Branch \(selection.branch) moved from expected head \(expectedHead) to \(latest)"
                )
            }
            throw OTodoError.conflict(
                message: "GitHub rejected non-force update of branch \(selection.branch) at expected head \(expectedHead) (HTTP \(response.statusCode)): \(apiMessage(response))"
            )
        }
        try validate(response, context: "updating branch \(selection.branch)")
    }

    private struct BranchState {
        let headCommitSHA: String
        let rootTreeSHA: String
    }

    private func fetchBranchState(owner: String, repository: String, branch: String) async throws -> BranchState {
        let head = try await fetchReferenceSHA(owner: owner, repository: repository, branch: branch)
        let response = try await request(
            method: "GET",
            path: try repositoryPath(owner, repository, suffix: "git/commits/\(percentEncodePathSegment(head))")
        )
        try validate(response, context: "reading commit \(head)", notFoundResource: "commit \(head)")
        let commit: GitHubCommitDTO = try decode(response, context: "reading commit \(head)")
        guard !commit.tree.sha.isEmpty else {
            throw OTodoError.transport(statusCode: response.statusCode, message: "GitHub returned an empty root tree SHA for commit \(head)")
        }
        return BranchState(headCommitSHA: head, rootTreeSHA: commit.tree.sha)
    }

    private func fetchReferenceSHA(owner: String, repository: String, branch: String) async throws -> String {
        let response = try await request(
            method: "GET",
            path: try repositoryPath(
                owner,
                repository,
                suffix: "git/ref/heads/\(percentEncodePathSegment(branch))"
            ),
            requiresFreshResponse: true
        )
        try validate(response, context: "reading branch \(branch)", notFoundResource: "branch \(branch)")
        let reference: GitHubReferenceDTO = try decode(response, context: "reading branch \(branch)")
        guard !reference.object.sha.isEmpty else {
            throw OTodoError.transport(statusCode: response.statusCode, message: "GitHub returned an empty head SHA for branch \(branch)")
        }
        return reference.object.sha
    }

    private func resolveTree(
        owner: String,
        repository: String,
        rootTreeSHA: String,
        path: String
    ) async throws -> String {
        guard !path.isEmpty else { return rootTreeSHA }
        let components = path.split(separator: "/")
        guard components.count <= resourceBudget.maximumTreeDepth else {
            throw resourceLimit("tree depth exceeded \(resourceBudget.maximumTreeDepth) while walking store path \(path)")
        }

        var currentSHA = rootTreeSHA
        var traversed = ""
        for componentSlice in components {
            let component = String(componentSlice)
            let tree = try await fetchTree(
                owner: owner,
                repository: repository,
                treeSHA: currentSHA,
                recursive: false,
                context: "walking store path \(path)"
            )
            guard let entry = tree.tree.first(where: { $0.path == component && $0.type == "tree" }) else {
                throw OTodoError.notFound(resource: "store path \(joinedPath(traversed, component))")
            }
            currentSHA = entry.sha
            traversed = joinedPath(traversed, component)
        }
        return currentSHA
    }

    private func recursivelyListTree(
        owner: String,
        repository: String,
        treeSHA: String,
        context: String
    ) async throws -> [GitHubTreeEntryDTO] {
        let recursive = try await fetchTree(
            owner: owner,
            repository: repository,
            treeSHA: treeSHA,
            recursive: true,
            context: context
        )
        guard recursive.truncated else { return recursive.tree }

        var result: [GitHubTreeEntryDTO] = []
        var pending: [(sha: String, prefix: String, depth: Int)] = [(treeSHA, "", 0)]
        var index = 0
        var requestCount = 0
        while index < pending.count {
            let item = pending[index]
            index += 1
            guard item.depth <= resourceBudget.maximumTreeDepth else {
                throw resourceLimit("tree depth exceeded \(resourceBudget.maximumTreeDepth) while \(context)")
            }
            guard requestCount < resourceBudget.maximumFallbackTreeRequests else {
                throw resourceLimit("fallback tree request count exceeded \(resourceBudget.maximumFallbackTreeRequests) while \(context)")
            }
            requestCount += 1

            let tree = try await fetchTree(
                owner: owner,
                repository: repository,
                treeSHA: item.sha,
                recursive: false,
                context: "\(context) after GitHub truncated a recursive tree"
            )
            guard tree.tree.count <= resourceBudget.maximumTreeEntries - result.count else {
                throw resourceLimit("tree entry count exceeded \(resourceBudget.maximumTreeEntries) while \(context)")
            }
            for entry in tree.tree {
                let fullPath = joinedPath(item.prefix, entry.path)
                let expanded = GitHubTreeEntryDTO(
                    path: fullPath,
                    mode: entry.mode,
                    type: entry.type,
                    sha: entry.sha,
                    size: entry.size
                )
                result.append(expanded)
                if entry.type == "tree" {
                    pending.append((entry.sha, fullPath, item.depth + 1))
                }
            }
        }
        return result
    }

    private func fetchTree(
        owner: String,
        repository: String,
        treeSHA: String,
        recursive: Bool,
        context: String
    ) async throws -> GitHubTreeDTO {
        let response = try await request(
            method: "GET",
            path: try repositoryPath(owner, repository, suffix: "git/trees/\(percentEncodePathSegment(treeSHA))"),
            queryItems: recursive ? [URLQueryItem(name: "recursive", value: "1")] : []
        )
        try validate(response, context: context, notFoundResource: "tree \(treeSHA)")
        let tree: GitHubTreeDTO = try decode(response, context: context)
        guard tree.tree.count <= resourceBudget.maximumTreeEntries else {
            throw resourceLimit("tree entry count exceeded \(resourceBudget.maximumTreeEntries) while \(context)")
        }
        return tree
    }

    private func fetchBlobText(
        owner: String,
        repository: String,
        sha: String,
        context: String,
        maximumBytes: Int,
        limitName: String
    ) async throws -> (text: String, byteCount: Int) {
        let response = try await request(
            method: "GET",
            path: try repositoryPath(owner, repository, suffix: "git/blobs/\(percentEncodePathSegment(sha))")
        )
        try validate(response, context: context, notFoundResource: "blob \(sha)")
        let blob: GitHubBlobDTO = try decode(response, context: context)

        let bytes: Data
        switch blob.encoding.lowercased() {
        case "base64":
            bytes = try decodeBase64(
                blob.content,
                maximumBytes: maximumBytes,
                statusCode: response.statusCode,
                context: context,
                limitName: limitName
            )
        case "utf-8", "utf8":
            let byteCount = blob.content.utf8.count
            guard byteCount <= maximumBytes else {
                throw resourceLimit(
                    "\(limitName) exceeded \(maximumBytes) decoded bytes while \(context)",
                    statusCode: response.statusCode
                )
            }
            bytes = Data(blob.content.utf8)
        default:
            throw OTodoError.transport(
                statusCode: response.statusCode,
                message: "GitHub returned unsupported blob encoding \(blob.encoding) for \(context)"
            )
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw OTodoError.transport(statusCode: response.statusCode, message: "GitHub blob is not valid UTF-8 for \(context)")
        }
        return (text, bytes.count)
    }

    private func decodeBase64(
        _ content: String,
        maximumBytes: Int,
        statusCode: Int,
        context: String,
        limitName: String
    ) throws -> Data {
        var decoded = Data()
        decoded.reserveCapacity(min(maximumBytes, (content.utf8.count / 4) * 3))
        var quartet: [UInt8] = []
        quartet.reserveCapacity(4)
        var finished = false

        func invalidBase64() -> OTodoError {
            OTodoError.transport(
                statusCode: statusCode,
                message: "GitHub returned invalid base64 for \(context)"
            )
        }

        for byte in content.utf8 {
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                continue
            }
            guard !finished else { throw invalidBase64() }

            let value: UInt8
            switch byte {
            case 0x41...0x5A:
                value = byte - 0x41
            case 0x61...0x7A:
                value = byte - 0x61 + 26
            case 0x30...0x39:
                value = byte - 0x30 + 52
            case 0x2B:
                value = 62
            case 0x2F:
                value = 63
            case 0x3D:
                value = 64
            default:
                throw invalidBase64()
            }
            quartet.append(value)
            guard quartet.count == 4 else { continue }

            guard quartet[0] < 64, quartet[1] < 64 else {
                throw invalidBase64()
            }
            let emittedCount: Int
            if quartet[2] == 64 {
                guard quartet[3] == 64 else { throw invalidBase64() }
                emittedCount = 1
                finished = true
            } else if quartet[3] == 64 {
                emittedCount = 2
                finished = true
            } else {
                emittedCount = 3
            }
            guard decoded.count <= maximumBytes - emittedCount else {
                throw resourceLimit(
                    "\(limitName) exceeded \(maximumBytes) decoded bytes while \(context)",
                    statusCode: statusCode
                )
            }

            decoded.append((quartet[0] << 2) | (quartet[1] >> 4))
            if emittedCount >= 2 {
                decoded.append((quartet[1] << 4) | (quartet[2] >> 2))
            }
            if emittedCount == 3 {
                decoded.append((quartet[2] << 6) | quartet[3])
            }
            quartet.removeAll(keepingCapacity: true)
        }

        guard quartet.isEmpty else { throw invalidBase64() }
        return decoded
    }

    private func validateKnownBlobSize(
        _ entry: GitHubTreeEntryDTO,
        maximumBytes: Int,
        resource: String
    ) throws {
        guard let size = entry.size else { return }
        guard size >= 0 else {
            throw OTodoError.transport(
                statusCode: nil,
                message: "GitHub returned a negative blob size for \(entry.path)"
            )
        }
        guard size <= maximumBytes else {
            throw resourceLimit("\(resource) exceeded \(maximumBytes) bytes")
        }
    }

    private func resourceLimit(_ message: String, statusCode: Int? = nil) -> OTodoError {
        OTodoError.transport(statusCode: statusCode, message: "GitHub resource limit exceeded: \(message)")
    }

    private func request(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        requiresFreshResponse: Bool = false
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()
        guard !accessToken.isEmpty,
              !accessToken.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw OTodoError.authentication(message: "A valid GitHub OAuth access token is required")
        }

        var request = URLRequest(url: try apiURL(path: path, queryItems: queryItems))
        if requiresFreshResponse {
            // GitHub advertises branch refs as cacheable for 60 seconds. A cached ref can
            // misclassify an ordinary head race as a rejected non-fast-forward update.
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("OTodo/1.0", forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await transport.send(request)
    }

    private func apiURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil
        else {
            throw OTodoError.transport(statusCode: nil, message: "Invalid GitHub API base URL")
        }
        let prefix = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + ([prefix, path].filter { !$0.isEmpty }.joined(separator: "/"))
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        components.fragment = nil
        guard let url = components.url else {
            throw OTodoError.transport(statusCode: nil, message: "Could not construct a GitHub API URL for \(path)")
        }
        return url
    }

    private func repositoryPath(_ owner: String, _ repository: String, suffix: String) throws -> String {
        guard !owner.isEmpty, !repository.isEmpty else {
            throw OTodoError.validation(field: "repository", message: "Repository owner and name are required")
        }
        return "repos/\(percentEncodePathSegment(owner))/\(percentEncodePathSegment(repository))/\(suffix)"
    }

    private func percentEncodePathSegment(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                result.unicodeScalars.append(UnicodeScalar(byte))
            default:
                result.append(String(format: "%%%02X", byte))
            }
        }
        return result
    }

    private func validate(
        _ response: HTTPResponse,
        context: String,
        notFoundResource: String? = nil
    ) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let message = apiMessage(response)
        switch response.statusCode {
        case 401:
            throw OTodoError.authentication(message: "GitHub rejected the OAuth access token while \(context): \(message)")
        case 404:
            throw OTodoError.notFound(resource: notFoundResource ?? "GitHub resource while \(context)")
        case 409:
            throw OTodoError.conflict(message: "GitHub conflict while \(context): \(message)")
        default:
            throw OTodoError.transport(statusCode: response.statusCode, message: "GitHub failed while \(context): \(message)")
        }
    }

    private func apiMessage(_ response: HTTPResponse) -> String {
        if let error = try? JSONDecoder().decode(GitHubAPIErrorDTO.self, from: response.body),
           !error.message.isEmpty
        {
            return error.message
        }
        if let text = String(data: response.body, encoding: .utf8), !text.isEmpty {
            return text
        }
        return "HTTP \(response.statusCode)"
    }

    private func decode<Value: Decodable>(_ response: HTTPResponse, context: String) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: response.body)
        } catch {
            throw OTodoError.transport(
                statusCode: response.statusCode,
                message: "GitHub returned invalid JSON while \(context): \(error.localizedDescription)"
            )
        }
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw OTodoError.transport(statusCode: nil, message: "Could not encode a GitHub request: \(error.localizedDescription)")
        }
    }

    private func isMarkdown(_ path: String, inside directory: String) -> Bool {
        path.hasPrefix(directory + "/") && path.hasSuffix(".md")
    }

    private func isPath(_ path: String, insideStore storePath: String) -> Bool {
        storePath.isEmpty || path.hasPrefix(storePath + "/")
    }

    private func joinedPath(_ prefix: String, _ suffix: String) -> String {
        prefix.isEmpty ? suffix : "\(prefix)/\(suffix)"
    }

    private func displayStorePath(_ path: String) -> String {
        path.isEmpty ? "repository root" : path
    }
}
