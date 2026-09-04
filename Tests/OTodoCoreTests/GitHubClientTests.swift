import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OTodoCore

final class GitHubClientTests: XCTestCase, @unchecked Sendable {
    private let oauthBaseURL = URL(string: "https://github.test/oauth")!
    private let apiBaseURL = URL(string: "https://api.github.test/v3")!
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    func testDeviceRequestUsesFormRepoScopeAndNoSecretOrAuthorization() async throws {
        let instant = instant
        let transport = ScriptedHTTPTransport(responses: [
            try jsonResponse([
                "device_code": "device-123",
                "user_code": "ABCD-EFGH",
                "verification_uri": "https://github.test/login/device",
                "expires_in": 900,
                "interval": 5,
            ]),
        ])
        let client = GitHubOAuthClient(
            clientID: "client id",
            transport: transport,
            baseURL: oauthBaseURL,
            now: { instant },
            sleep: { _ in XCTFail("Starting Device Flow must not sleep") }
        )

        let device = try await client.startDeviceFlow()

        XCTAssertEqual(device.deviceCode, "device-123")
        XCTAssertEqual(device.userCode, "ABCD-EFGH")
        XCTAssertEqual(device.verificationURI.absoluteString, "https://github.test/login/device")
        XCTAssertEqual(device.expiresAt, instant.addingTimeInterval(900))
        XCTAssertEqual(device.pollingInterval, 5)

        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.only)
        assertOAuthRequest(
            request,
            path: "/oauth/login/device/code",
            form: "client_id=client+id&scope=repo"
        )
    }

    func testPollingPersistsSlowDownIntervalUntilRotatingTokenArrives() async throws {
        let instant = instant
        let transport = ScriptedHTTPTransport(responses: [
            try jsonResponse(["error": "authorization_pending"]),
            try jsonResponse(["error": "slow_down"]),
            try jsonResponse(["error": "authorization_pending"]),
            try jsonResponse([
                "access_token": "access-one",
                "refresh_token": "refresh-one",
                "token_type": "bearer",
                "scope": "repo",
                "expires_in": 3_600,
                "refresh_token_expires_in": 86_400,
            ]),
        ])
        let sleeps = SleepRecorder()
        let client = GitHubOAuthClient(
            clientID: "client-id",
            transport: transport,
            baseURL: oauthBaseURL,
            now: { instant },
            sleep: { seconds in await sleeps.record(seconds) }
        )
        let device = OAuthDeviceCode(
            deviceCode: "device-123",
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://github.test/login/device")!,
            expiresAt: instant.addingTimeInterval(600),
            pollingInterval: 2
        )

        let token = try await client.pollForToken(deviceCode: device)

        XCTAssertEqual(token.accessToken, "access-one")
        XCTAssertEqual(token.refreshToken, "refresh-one")
        XCTAssertEqual(token.tokenType, "bearer")
        XCTAssertEqual(token.scope, "repo")
        XCTAssertEqual(token.accessTokenExpiresAt, instant.addingTimeInterval(3_600))
        XCTAssertEqual(token.refreshTokenExpiresAt, instant.addingTimeInterval(86_400))
        let intervals = await sleeps.intervals()
        XCTAssertEqual(intervals, [2, 2, 7, 7])

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 4)
        for request in requests {
            assertOAuthRequest(
                request,
                path: "/oauth/login/oauth/access_token",
                form: "client_id=client-id&device_code=device-123&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
            )
        }
    }

    func testPollingRetriesConnectionLossUntilTokenArrives() async throws {
        let instant = instant
        let transport = ConnectionLossThenResponseTransport(response: try jsonResponse([
            "access_token": "access-after-reconnect",
            "token_type": "bearer",
            "scope": "repo",
        ]))
        let sleeps = SleepRecorder()
        let client = GitHubOAuthClient(
            clientID: "client-id",
            transport: transport,
            baseURL: oauthBaseURL,
            now: { instant },
            sleep: { seconds in await sleeps.record(seconds) }
        )
        let device = OAuthDeviceCode(
            deviceCode: "device-123",
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://github.test/login/device")!,
            expiresAt: instant.addingTimeInterval(600),
            pollingInterval: 2
        )

        let token = try await client.pollForToken(deviceCode: device)

        let requestCount = await transport.requestsSent()
        let intervals = await sleeps.intervals()
        XCTAssertEqual(token.accessToken, "access-after-reconnect")
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(intervals, [2, 2])
    }

    func testPollingReportsDenialAndExpiresBeforeSleepingOrSending() async throws {
        let instant = instant
        let denialTransport = ScriptedHTTPTransport(responses: [
            try jsonResponse([
                "error": "access_denied",
                "error_description": "The user declined authorization",
            ]),
        ])
        let denialSleeps = SleepRecorder()
        let denialClient = GitHubOAuthClient(
            clientID: "client-id",
            transport: denialTransport,
            baseURL: oauthBaseURL,
            now: { instant },
            sleep: { seconds in await denialSleeps.record(seconds) }
        )
        let activeDevice = OAuthDeviceCode(
            deviceCode: "active-device",
            userCode: "ACTIVE",
            verificationURI: URL(string: "https://github.test/login/device")!,
            expiresAt: instant.addingTimeInterval(60),
            pollingInterval: 3
        )

        do {
            _ = try await denialClient.pollForToken(deviceCode: activeDevice)
            XCTFail("Expected access denial")
        } catch {
            XCTAssertEqual(
                error as? OTodoError,
                OTodoError.authentication(message: "The user declined authorization")
            )
        }
        let denialIntervals = await denialSleeps.intervals()
        XCTAssertEqual(denialIntervals, [3])
        let denialRequests = await denialTransport.requests()
        XCTAssertEqual(denialRequests.count, 1)
        if let request = denialRequests.first {
            assertOAuthRequest(
                request,
                path: "/oauth/login/oauth/access_token",
                form: "client_id=client-id&device_code=active-device&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
            )
        }

        let serverExpiryTransport = ScriptedHTTPTransport(responses: [
            try jsonResponse([
                "error": "expired_token",
                "error_description": "The device code expired on GitHub",
            ]),
        ])
        let serverExpirySleeps = SleepRecorder()
        let serverExpiryClient = GitHubOAuthClient(
            clientID: "client-id",
            transport: serverExpiryTransport,
            baseURL: oauthBaseURL,
            now: { instant },
            sleep: { seconds in await serverExpirySleeps.record(seconds) }
        )
        do {
            _ = try await serverExpiryClient.pollForToken(deviceCode: activeDevice)
            XCTFail("Expected GitHub-reported expiration")
        } catch {
            XCTAssertEqual(
                error as? OTodoError,
                OTodoError.authentication(message: "The device code expired on GitHub")
            )
        }
        let serverExpiryIntervals = await serverExpirySleeps.intervals()
        XCTAssertEqual(serverExpiryIntervals, [3])
        let serverExpiryRequests = await serverExpiryTransport.requests()
        XCTAssertEqual(serverExpiryRequests.count, 1)
        if let request = serverExpiryRequests.first {
            assertOAuthRequest(
                request,
                path: "/oauth/login/oauth/access_token",
                form: "client_id=client-id&device_code=active-device&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
            )
        }

        let expiryTransport = ScriptedHTTPTransport(responses: [])
        let expirySleeps = SleepRecorder()
        let expiryClient = GitHubOAuthClient(
            clientID: "client-id",
            transport: expiryTransport,
            baseURL: oauthBaseURL,
            now: { instant },
            sleep: { seconds in await expirySleeps.record(seconds) }
        )
        let expiredDevice = OAuthDeviceCode(
            deviceCode: "expired-device",
            userCode: "EXPIRED",
            verificationURI: URL(string: "https://github.test/login/device")!,
            expiresAt: instant,
            pollingInterval: 3
        )

        do {
            _ = try await expiryClient.pollForToken(deviceCode: expiredDevice)
            XCTFail("Expected expiration")
        } catch {
            XCTAssertEqual(
                error as? OTodoError,
                OTodoError.authentication(message: "The GitHub device authorization expired")
            )
        }
        let expiryIntervals = await expirySleeps.intervals()
        XCTAssertTrue(expiryIntervals.isEmpty)
        let expiryRequests = await expiryTransport.requests()
        XCTAssertTrue(expiryRequests.isEmpty)
    }

    func testRefreshIsSecretlessAndReturnsAllRotatedCredentials() async throws {
        let instant = instant
        let transport = ScriptedHTTPTransport(responses: [
            try jsonResponse([
                "access_token": "new-access",
                "refresh_token": "new-refresh",
                "token_type": "bearer",
                "scope": "repo gist",
                "expires_in": 7_200,
                "refresh_token_expires_in": 172_800,
            ]),
        ])
        let client = GitHubOAuthClient(
            clientID: "client-id",
            transport: transport,
            baseURL: oauthBaseURL,
            now: { instant },
            sleep: { _ in XCTFail("Refresh must not sleep") }
        )
        let oldToken = OAuthTokenPair(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            tokenType: "bearer",
            scope: "repo",
            accessTokenExpiresAt: instant.addingTimeInterval(10),
            refreshTokenExpiresAt: instant.addingTimeInterval(20)
        )

        let refreshed = try await client.refreshToken(oldToken)

        XCTAssertEqual(refreshed.accessToken, "new-access")
        XCTAssertEqual(refreshed.refreshToken, "new-refresh")
        XCTAssertEqual(refreshed.tokenType, "bearer")
        XCTAssertEqual(refreshed.scope, "repo gist")
        XCTAssertEqual(refreshed.accessTokenExpiresAt, instant.addingTimeInterval(7_200))
        XCTAssertEqual(refreshed.refreshTokenExpiresAt, instant.addingTimeInterval(172_800))

        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.only)
        assertOAuthRequest(
            request,
            path: "/oauth/login/oauth/access_token",
            form: "client_id=client-id&grant_type=refresh_token&refresh_token=old-refresh"
        )
    }

    func testRepositoryListingUsesRequiredHeadersAndPaginatesUntilShortPage() async throws {
        let firstPage = (0..<100).map { index in
            repositoryJSON(name: String(format: "repo-%03d", index), isPrivate: index.isMultiple(of: 2))
        }
        let transport = ScriptedHTTPTransport(responses: [
            try jsonResponse(firstPage),
            try jsonResponse([repositoryJSON(name: "repo-100", isPrivate: true)]),
        ])
        let client = GitHubAPIClient(
            accessToken: "access-token",
            transport: transport,
            baseURL: apiBaseURL
        )

        let repositories = try await client.listRepositories()

        XCTAssertEqual(repositories.count, 101)
        XCTAssertEqual(
            repositories.first,
            RepositorySummary(owner: "acme", name: "repo-000", defaultBranch: "main", isPrivate: true)
        )
        XCTAssertEqual(
            repositories.last,
            RepositorySummary(owner: "acme", name: "repo-100", defaultBranch: "main", isPrivate: true)
        )

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        for (index, request) in requests.enumerated() {
            assertRESTRequest(request, method: "GET", path: "/v3/user/repos")
            XCTAssertEqual(
                request.queryItems,
                [
                    "visibility=all",
                    "affiliation=owner,collaborator,organization_member",
                    "sort=full_name",
                    "direction=asc",
                    "per_page=100",
                    "page=\(index + 1)",
                ]
            )
            XCTAssertNil(request.header(named: "Content-Type"))
            XCTAssertNil(request.body)
        }
    }

    func testStoreDiscoveryReadsBranchAndFindsRootAndNestedStores() async throws {
        let transport = ScriptedHTTPTransport(responses: [
            try jsonResponse(["object": ["sha": "head-1"]]),
            try jsonResponse(["sha": "head-1", "tree": ["sha": "root-tree"]]),
            try treeResponse(
                sha: "root-tree",
                entries: [
                    treeEntry(path: ".todo/config.toml", type: "blob", sha: "config-root"),
                    treeEntry(path: "notes/readme.md", type: "blob", sha: "readme"),
                    treeEntry(path: "teams/red/.todo/config.toml", type: "blob", sha: "config-red"),
                    treeEntry(path: "teams/blue/.todo/config.toml", type: "blob", sha: "config-blue"),
                ]
            ),
        ])
        let client = GitHubAPIClient(
            accessToken: "access-token",
            transport: transport,
            baseURL: apiBaseURL
        )
        let repository = RepositorySummary(
            owner: "acme",
            name: "vault",
            defaultBranch: "main",
            isPrivate: true
        )

        let paths = try await client.discoverStorePaths(repository: repository, branch: "feature/todos")

        XCTAssertEqual(paths, ["", "teams/blue", "teams/red"])
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 3)
        assertRESTRequest(requests[0], method: "GET", path: "/v3/repos/acme/vault/git/ref/heads/feature%2Ftodos")
        XCTAssertTrue(requests[0].queryItems.isEmpty)
        assertRESTRequest(requests[1], method: "GET", path: "/v3/repos/acme/vault/git/commits/head-1")
        XCTAssertTrue(requests[1].queryItems.isEmpty)
        assertRESTRequest(requests[2], method: "GET", path: "/v3/repos/acme/vault/git/trees/root-tree")
        XCTAssertEqual(requests[2].queryItems, ["recursive=1"])
    }

    func testSparseSnapshotFallsBackFromTruncatedTreeAndFetchesOnlySelectedBlobs() async throws {
        let configuration = """
        schema_version = 1
        tasks_directory = "Tasks"
        projects_directory = "Projects"
        obsidian_link_prefix = "Vault"
        default_state = "open"

        [[states]]
        id = "open"
        name = "Open"
        terminal = false
        """
        let taskText = "---\nname: Task\nstate: open\n---\nBody\n"
        let projectText = "# Project\n"
        let transport = ScriptedHTTPTransport(responses: [
            try jsonResponse(["object": ["sha": "head-1"]]),
            try jsonResponse(["sha": "head-1", "tree": ["sha": "root-tree"]]),
            try treeResponse(
                sha: "root-tree",
                entries: [treeEntry(path: "Vault", type: "tree", sha: "store-tree")]
            ),
            try treeResponse(sha: "store-tree", entries: [], truncated: true),
            try treeResponse(
                sha: "store-tree",
                entries: [
                    treeEntry(path: ".todo", type: "tree", sha: "todo-tree"),
                    treeEntry(path: "Tasks", type: "tree", sha: "tasks-tree"),
                    treeEntry(path: "Projects", type: "tree", sha: "projects-tree"),
                    treeEntry(path: "ignored.txt", type: "blob", sha: "ignored-blob"),
                ]
            ),
            try treeResponse(
                sha: "todo-tree",
                entries: [treeEntry(path: "config.toml", type: "blob", sha: "config-blob")]
            ),
            try treeResponse(
                sha: "tasks-tree",
                entries: [
                    treeEntry(path: "task.md", type: "blob", sha: "task-blob"),
                    treeEntry(path: "draft.txt", type: "blob", sha: "draft-blob"),
                ]
            ),
            try treeResponse(
                sha: "projects-tree",
                entries: [treeEntry(path: "project.md", type: "blob", sha: "project-blob")]
            ),
            try blobResponse(configuration),
            try blobResponse(projectText),
            try blobResponse(taskText),
        ])
        let client = GitHubAPIClient(
            accessToken: "access-token",
            transport: transport,
            baseURL: apiBaseURL,
            configurationCodec: StrictStoreConfigCodec(),
            resourceBudget: resourceBudget(
                maximumFallbackTreeRequests: 4,
                maximumTreeDepth: 1,
                maximumTreeEntries: 8,
                maximumSelectedFiles: 3,
                maximumRecordBytes: max(taskText.utf8.count, projectText.utf8.count),
                maximumConfigurationBytes: configuration.utf8.count,
                maximumAggregateBlobBytes: configuration.utf8.count + taskText.utf8.count + projectText.utf8.count
            )
        )
        let selection = try RepositorySelection(
            owner: "acme",
            name: "vault",
            branch: "main",
            storePath: "Vault"
        )

        let snapshot = try await client.fetchSnapshot(selection: selection)

        XCTAssertEqual(snapshot.headCommitSHA, "head-1")
        XCTAssertEqual(snapshot.rootTreeSHA, "root-tree")
        XCTAssertEqual(
            snapshot.files,
            [
                try RemoteFile(path: "Vault/.todo/config.toml", blobSHA: "config-blob", content: configuration),
                try RemoteFile(path: "Vault/Projects/project.md", blobSHA: "project-blob", content: projectText),
                try RemoteFile(path: "Vault/Tasks/task.md", blobSHA: "task-blob", content: taskText),
            ]
        )

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 11)
        let expected: [(String, [String])] = [
            ("/v3/repos/acme/vault/git/ref/heads/main", []),
            ("/v3/repos/acme/vault/git/commits/head-1", []),
            ("/v3/repos/acme/vault/git/trees/root-tree", []),
            ("/v3/repos/acme/vault/git/trees/store-tree", ["recursive=1"]),
            ("/v3/repos/acme/vault/git/trees/store-tree", []),
            ("/v3/repos/acme/vault/git/trees/todo-tree", []),
            ("/v3/repos/acme/vault/git/trees/tasks-tree", []),
            ("/v3/repos/acme/vault/git/trees/projects-tree", []),
            ("/v3/repos/acme/vault/git/blobs/config-blob", []),
            ("/v3/repos/acme/vault/git/blobs/project-blob", []),
            ("/v3/repos/acme/vault/git/blobs/task-blob", []),
        ]
        for (request, expectedRequest) in zip(requests, expected) {
            assertRESTRequest(request, method: "GET", path: expectedRequest.0)
            XCTAssertEqual(request.queryItems, expectedRequest.1)
        }
        XCTAssertFalse(requests.contains { $0.url.absoluteString.contains("ignored-blob") })
        XCTAssertFalse(requests.contains { $0.url.absoluteString.contains("draft-blob") })
    }

    func testTruncatedFallbackStopsAtRequestBudgetBeforeAnotherTreeRequest() async throws {
        var responses = try snapshotPrelude(entries: [], truncated: true)
        responses.append(try treeResponse(
            sha: "root-tree",
            entries: [treeEntry(path: "first", type: "tree", sha: "first-tree")]
        ))
        responses.append(try treeResponse(
            sha: "first-tree",
            entries: [treeEntry(path: "second", type: "tree", sha: "second-tree")]
        ))
        let transport = ScriptedHTTPTransport(responses: responses)
        let client = GitHubAPIClient(
            accessToken: "access-token",
            transport: transport,
            baseURL: apiBaseURL,
            configurationCodec: StrictStoreConfigCodec(),
            resourceBudget: resourceBudget(maximumFallbackTreeRequests: 2)
        )

        do {
            _ = try await client.fetchSnapshot(selection: rootSelection())
            XCTFail("Expected the fallback tree request budget to reject the snapshot")
        } catch {
            assertResourceLimitError(error)
        }

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 5)
        XCTAssertFalse(requests.contains { $0.url.path.hasSuffix("/git/trees/second-tree") })
    }

    func testTruncatedFallbackStopsAtDepthBudgetBeforeDeeperTreeRequest() async throws {
        var responses = try snapshotPrelude(entries: [], truncated: true)
        responses.append(try treeResponse(
            sha: "root-tree",
            entries: [treeEntry(path: "first", type: "tree", sha: "first-tree")]
        ))
        responses.append(try treeResponse(
            sha: "first-tree",
            entries: [treeEntry(path: "second", type: "tree", sha: "second-tree")]
        ))
        let transport = ScriptedHTTPTransport(responses: responses)
        let client = GitHubAPIClient(
            accessToken: "access-token",
            transport: transport,
            baseURL: apiBaseURL,
            configurationCodec: StrictStoreConfigCodec(),
            resourceBudget: resourceBudget(
                maximumFallbackTreeRequests: 3,
                maximumTreeDepth: 1
            )
        )

        do {
            _ = try await client.fetchSnapshot(selection: rootSelection())
            XCTFail("Expected the fallback tree depth budget to reject the snapshot")
        } catch {
            assertResourceLimitError(error)
        }

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 5)
        XCTAssertFalse(requests.contains { $0.url.path.hasSuffix("/git/trees/second-tree") })
    }

    func testTruncatedFallbackRejectsExcessiveEntriesAtResponseBoundary() async throws {
        let entryBudget = 2
        var responses = try snapshotPrelude(entries: [], truncated: true)
        responses.append(try treeResponse(
            sha: "root-tree",
            entries: (0...entryBudget).map {
                treeEntry(path: "ignored-\($0).txt", type: "blob", sha: "ignored-\($0)")
            }
        ))
        let transport = ScriptedHTTPTransport(responses: responses)
        let client = GitHubAPIClient(
            accessToken: "access-token",
            transport: transport,
            baseURL: apiBaseURL,
            configurationCodec: StrictStoreConfigCodec(),
            resourceBudget: resourceBudget(maximumTreeEntries: entryBudget)
        )

        do {
            _ = try await client.fetchSnapshot(selection: rootSelection())
            XCTFail("Expected the fallback tree entry budget to reject the snapshot")
        } catch {
            assertResourceLimitError(error)
        }

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 4)
    }

    func testSnapshotRejectsTreeDeclaredOversizedSelectedBlobBeforeBlobRequest() async throws {
        let configuration = compactStoreConfiguration()
        let recordBudget = 8
        var responses = try snapshotPrelude(entries: [
            treeEntry(
                path: ".todo/config.toml",
                type: "blob",
                sha: "config-blob",
                size: configuration.utf8.count
            ),
            treeEntry(
                path: "Tasks/large.md",
                type: "blob",
                sha: "large-task",
                size: recordBudget + 1
            ),
        ])
        responses.append(try blobResponse(configuration))
        let transport = ScriptedHTTPTransport(responses: responses)
        let client = GitHubAPIClient(
            accessToken: "access-token",
            transport: transport,
            baseURL: apiBaseURL,
            configurationCodec: StrictStoreConfigCodec(),
            resourceBudget: resourceBudget(maximumRecordBytes: recordBudget)
        )

        do {
            _ = try await client.fetchSnapshot(selection: rootSelection())
            XCTFail("Expected the declared blob size to reject the snapshot")
        } catch {
            assertResourceLimitError(error)
        }

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertFalse(requests.contains { $0.url.path.hasSuffix("/git/blobs/large-task") })
    }

    func testSnapshotRejectsExcessiveSelectedFileCountBeforeTaskBlobRequests() async throws {
        let configuration = compactStoreConfiguration()
        let selectedFileBudget = 2
        var responses = try snapshotPrelude(entries: [
            treeEntry(path: ".todo/config.toml", type: "blob", sha: "config-blob"),
            treeEntry(path: "Tasks/one.md", type: "blob", sha: "task-one"),
            treeEntry(path: "Tasks/two.md", type: "blob", sha: "task-two"),
        ])
        responses.append(try blobResponse(configuration))
        let transport = ScriptedHTTPTransport(responses: responses)
        let client = GitHubAPIClient(
            accessToken: "access-token",
            transport: transport,
            baseURL: apiBaseURL,
            configurationCodec: StrictStoreConfigCodec(),
            resourceBudget: resourceBudget(maximumSelectedFiles: selectedFileBudget)
        )

        do {
            _ = try await client.fetchSnapshot(selection: rootSelection())
            XCTFail("Expected the selected file budget to reject the snapshot")
        } catch {
            assertResourceLimitError(error)
        }

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertFalse(requests.contains { $0.url.path.contains("/git/blobs/task-") })
    }

    func testSnapshotRejectsOversizedDecodedRecordWhenTreeOmitsSize() async throws {
        let configuration = compactStoreConfiguration()
        let recordBudget = 8
        let oversizedRecord = String(repeating: "x", count: recordBudget + 1)
        var responses = try snapshotPrelude(entries: [
            treeEntry(path: ".todo/config.toml", type: "blob", sha: "config-blob"),
            treeEntry(path: "Tasks/large.md", type: "blob", sha: "large-task"),
        ])
        responses.append(try blobResponse(configuration))
        responses.append(try blobResponse(oversizedRecord))
        let transport = ScriptedHTTPTransport(responses: responses)
        let client = GitHubAPIClient(
            accessToken: "access-token",
            transport: transport,
            baseURL: apiBaseURL,
            configurationCodec: StrictStoreConfigCodec(),
            resourceBudget: resourceBudget(maximumRecordBytes: recordBudget)
        )

        do {
            _ = try await client.fetchSnapshot(selection: rootSelection())
            XCTFail("Expected the decoded record byte budget to reject the snapshot")
        } catch {
            assertResourceLimitError(error)
        }

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 5)
    }

    func testSnapshotRejectsAggregateDecodedBytesWithoutReturningPartialSnapshot() async throws {
        let configuration = compactStoreConfiguration()
        let firstRecord = "1234"
        let secondRecord = "56789"
        let aggregateBudget = configuration.utf8.count + firstRecord.utf8.count
        var responses = try snapshotPrelude(entries: [
            treeEntry(path: ".todo/config.toml", type: "blob", sha: "config-blob"),
            treeEntry(path: "Tasks/one.md", type: "blob", sha: "task-one"),
            treeEntry(path: "Tasks/two.md", type: "blob", sha: "task-two"),
        ])
        responses.append(try blobResponse(configuration))
        responses.append(try blobResponse(firstRecord))
        responses.append(try blobResponse(secondRecord))
        let transport = ScriptedHTTPTransport(responses: responses)
        let client = GitHubAPIClient(
            accessToken: "access-token",
            transport: transport,
            baseURL: apiBaseURL,
            configurationCodec: StrictStoreConfigCodec(),
            resourceBudget: resourceBudget(
                maximumRecordBytes: secondRecord.utf8.count,
                maximumAggregateBlobBytes: aggregateBudget
            )
        )

        do {
            _ = try await client.fetchSnapshot(selection: rootSelection())
            XCTFail("Expected the aggregate decoded byte budget to reject the snapshot")
        } catch {
            assertResourceLimitError(error)
        }

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 6)
    }

    func testCommitOverlaysRootTreeWithCreatedAndDeletedBlobPathsAndImmutableParent() async throws {
        let transport = ScriptedHTTPTransport(responses: [
            try jsonResponse(["sha": "new-blob"]),
            try jsonResponse(["sha": "new-tree"]),
            try jsonResponse(["sha": "new-commit"]),
        ])
        let client = GitHubAPIClient(
            accessToken: "access-token",
            transport: transport,
            baseURL: apiBaseURL
        )
        let selection = try RepositorySelection(
            owner: "acme",
            name: "vault",
            branch: "main",
            storePath: "Vault"
        )
        let snapshot = try GitSnapshot(
            headCommitSHA: "immutable-head",
            rootTreeSHA: "immutable-root-tree",
            files: []
        )
        let changes = [
            try RemoteChange(path: "Vault/Tasks/new.md", content: "new contents"),
            try RemoteChange(path: "Vault/Tasks/old.md", content: nil),
        ]

        let commitSHA = try await client.commit(
            selection: selection,
            changes: changes,
            against: snapshot,
            message: "Update todo files"
        )

        XCTAssertEqual(commitSHA, "new-commit")
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 3)
        assertRESTRequest(requests[0], method: "POST", path: "/v3/repos/acme/vault/git/blobs", hasJSONBody: true)
        assertRESTRequest(requests[1], method: "POST", path: "/v3/repos/acme/vault/git/trees", hasJSONBody: true)
        assertRESTRequest(requests[2], method: "POST", path: "/v3/repos/acme/vault/git/commits", hasJSONBody: true)

        let blobBody = try requests[0].jsonObject()
        XCTAssertEqual(blobBody["content"] as? String, "new contents")
        XCTAssertEqual(blobBody["encoding"] as? String, "utf-8")

        let treeBody = try requests[1].jsonObject()
        XCTAssertEqual(treeBody["base_tree"] as? String, "immutable-root-tree")
        let tree = try XCTUnwrap(treeBody["tree"] as? [[String: Any]])
        XCTAssertEqual(tree.count, 2)
        XCTAssertEqual(tree[0]["path"] as? String, "Vault/Tasks/new.md")
        XCTAssertEqual(tree[0]["mode"] as? String, "100644")
        XCTAssertEqual(tree[0]["type"] as? String, "blob")
        XCTAssertEqual(tree[0]["sha"] as? String, "new-blob")
        XCTAssertEqual(tree[1]["path"] as? String, "Vault/Tasks/old.md")
        XCTAssertEqual(tree[1]["mode"] as? String, "100644")
        XCTAssertEqual(tree[1]["type"] as? String, "blob")
        XCTAssertTrue(tree[1]["sha"] is NSNull)

        let commitBody = try requests[2].jsonObject()
        XCTAssertEqual(commitBody["message"] as? String, "Update todo files")
        XCTAssertEqual(commitBody["tree"] as? String, "new-tree")
        XCTAssertEqual(commitBody["parents"] as? [String], ["immutable-head"])
    }

    func testReferenceUpdateChecksExpectedHeadNeverForcesAndClassifiesRaces() async throws {
        let selection = try RepositorySelection(
            owner: "acme",
            name: "vault",
            branch: "main",
            storePath: "Vault"
        )
        let successTransport = ScriptedHTTPTransport(responses: [
            try jsonResponse(["object": ["sha": "expected-head"]]),
            try jsonResponse(["object": ["sha": "new-commit"]]),
        ])
        let successClient = GitHubAPIClient(
            accessToken: "access-token",
            transport: successTransport,
            baseURL: apiBaseURL
        )

        try await successClient.updateReference(
            selection: selection,
            to: "new-commit",
            expectedHead: "expected-head"
        )

        let successRequests = await successTransport.requests()
        XCTAssertEqual(successRequests.count, 2)
        assertRESTRequest(successRequests[0], method: "GET", path: "/v3/repos/acme/vault/git/ref/heads/main")
        assertRESTRequest(successRequests[1], method: "PATCH", path: "/v3/repos/acme/vault/git/refs/heads/main", hasJSONBody: true)
        let updateBody = try successRequests[1].jsonObject()
        XCTAssertEqual(updateBody["sha"] as? String, "new-commit")
        XCTAssertEqual(updateBody["force"] as? Bool, false)

        let raceTransport = ScriptedHTTPTransport(responses: [
            try jsonResponse(["object": ["sha": "expected-head"]]),
            try jsonResponse(["message": "Update is not a fast forward"], statusCode: 422),
            try jsonResponse(["object": ["sha": "racing-head"]]),
        ])
        let raceClient = GitHubAPIClient(
            accessToken: "access-token",
            transport: raceTransport,
            baseURL: apiBaseURL
        )
        do {
            try await raceClient.updateReference(
                selection: selection,
                to: "our-commit",
                expectedHead: "expected-head"
            )
            XCTFail("Expected a branch race")
        } catch {
            XCTAssertEqual(
                error as? OTodoError,
                OTodoError.conflict(message: "Branch main moved from expected head expected-head to racing-head")
            )
        }
        let raceRequests = await raceTransport.requests()
        XCTAssertEqual(raceRequests.count, 3)
        assertRESTRequest(raceRequests[0], method: "GET", path: "/v3/repos/acme/vault/git/ref/heads/main")
        assertRESTRequest(raceRequests[1], method: "PATCH", path: "/v3/repos/acme/vault/git/refs/heads/main", hasJSONBody: true)
        assertRESTRequest(raceRequests[2], method: "GET", path: "/v3/repos/acme/vault/git/ref/heads/main")
        let raceBody = try raceRequests[1].jsonObject()
        XCTAssertEqual(raceBody["sha"] as? String, "our-commit")
        XCTAssertEqual(raceBody["force"] as? Bool, false)

        let rejectionTransport = ScriptedHTTPTransport(responses: [
            try jsonResponse(["object": ["sha": "expected-head"]]),
            try jsonResponse(["message": "Protected branch"], statusCode: 409),
            try jsonResponse(["object": ["sha": "expected-head"]]),
        ])
        let rejectionClient = GitHubAPIClient(
            accessToken: "access-token",
            transport: rejectionTransport,
            baseURL: apiBaseURL
        )
        do {
            try await rejectionClient.updateReference(
                selection: selection,
                to: "our-commit",
                expectedHead: "expected-head"
            )
            XCTFail("Expected non-force rejection")
        } catch {
            XCTAssertEqual(
                error as? OTodoError,
                OTodoError.conflict(
                    message: "GitHub rejected non-force update of branch main at expected head expected-head (HTTP 409): Protected branch"
                )
            )
        }
        let rejectionRequests = await rejectionTransport.requests()
        XCTAssertEqual(rejectionRequests.count, 3)
        assertRESTRequest(rejectionRequests[1], method: "PATCH", path: "/v3/repos/acme/vault/git/refs/heads/main", hasJSONBody: true)
        let rejectionBody = try rejectionRequests[1].jsonObject()
        XCTAssertEqual(rejectionBody["force"] as? Bool, false)

        let staleTransport = ScriptedHTTPTransport(responses: [
            try jsonResponse(["object": ["sha": "already-moved-head"]]),
        ])
        let staleClient = GitHubAPIClient(
            accessToken: "access-token",
            transport: staleTransport,
            baseURL: apiBaseURL
        )
        do {
            try await staleClient.updateReference(
                selection: selection,
                to: "our-commit",
                expectedHead: "expected-head"
            )
            XCTFail("Expected stale expected head rejection")
        } catch {
            XCTAssertEqual(
                error as? OTodoError,
                OTodoError.conflict(
                    message: "Branch main moved from expected head expected-head to already-moved-head"
                )
            )
        }
        let staleRequests = await staleTransport.requests()
        XCTAssertEqual(staleRequests.count, 1)
        assertRESTRequest(staleRequests[0], method: "GET", path: "/v3/repos/acme/vault/git/ref/heads/main")
    }

    private func assertOAuthRequest(
        _ request: CapturedRequest,
        path: String,
        form: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(request.method, "POST", file: file, line: line)
        XCTAssertEqual(request.url.scheme, "https", file: file, line: line)
        XCTAssertEqual(request.url.host, "github.test", file: file, line: line)
        XCTAssertEqual(request.url.path, path, file: file, line: line)
        XCTAssertTrue(request.queryItems.isEmpty, file: file, line: line)
        XCTAssertEqual(request.header(named: "Accept"), "application/json", file: file, line: line)
        XCTAssertEqual(
            request.header(named: "Content-Type"),
            "application/x-www-form-urlencoded",
            file: file,
            line: line
        )
        XCTAssertEqual(request.header(named: "User-Agent"), "OTodo/1.0", file: file, line: line)
        XCTAssertNil(request.header(named: "Authorization"), file: file, line: line)
        let body = request.body.flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(body, form, file: file, line: line)
        XCTAssertFalse(body?.lowercased().contains("secret") ?? true, file: file, line: line)
    }

    private func assertRESTRequest(
        _ request: CapturedRequest,
        method: String,
        path: String,
        hasJSONBody: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(request.method, method, file: file, line: line)
        XCTAssertEqual(request.url.scheme, "https", file: file, line: line)
        XCTAssertEqual(request.url.host, "api.github.test", file: file, line: line)
        let percentEncodedPath = URLComponents(
            url: request.url,
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath
        XCTAssertEqual(percentEncodedPath, path, file: file, line: line)
        XCTAssertEqual(request.header(named: "Authorization"), "Bearer access-token", file: file, line: line)
        XCTAssertEqual(request.header(named: "Accept"), "application/vnd.github+json", file: file, line: line)
        XCTAssertEqual(request.header(named: "X-GitHub-Api-Version"), "2026-03-10", file: file, line: line)
        XCTAssertEqual(request.header(named: "User-Agent"), "OTodo/1.0", file: file, line: line)
        XCTAssertEqual(
            request.header(named: "Content-Type"),
            hasJSONBody ? "application/json" : nil,
            file: file,
            line: line
        )
        XCTAssertEqual(request.body != nil, hasJSONBody, file: file, line: line)
    }
}

private struct CapturedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?

    var queryItems: [String] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map {
            "\($0.name)=\($0.value ?? "")"
        } ?? []
    }

    func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func jsonObject() throws -> [String: Any] {
        let data = try XCTUnwrap(body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor ScriptedHTTPTransport: HTTPTransport {
    private let responses: [HTTPResponse]
    private var responseIndex = 0
    private var capturedRequests: [CapturedRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        capturedRequests.append(CapturedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody
        ))
        guard responseIndex < responses.count else {
            throw ScriptError.unexpectedRequest(request.url?.absoluteString ?? "missing URL")
        }
        let response = responses[responseIndex]
        responseIndex += 1
        return response
    }

    func requests() -> [CapturedRequest] {
        capturedRequests
    }
}

private actor ConnectionLossThenResponseTransport: HTTPTransport {
    private let response: HTTPResponse
    private var requestCount = 0

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requestCount += 1
        if requestCount == 1 {
            throw OTodoError.transport(
                statusCode: nil,
                message: "The network connection was lost."
            )
        }
        return response
    }

    func requestsSent() -> Int {
        requestCount
    }
}

private actor SleepRecorder {
    private var recordedIntervals: [TimeInterval] = []

    func record(_ interval: TimeInterval) {
        recordedIntervals.append(interval)
    }

    func intervals() -> [TimeInterval] {
        recordedIntervals
    }
}

private enum ScriptError: Error {
    case unexpectedRequest(String)
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}

private func repositoryJSON(name: String, isPrivate: Bool) -> [String: Any] {
    [
        "name": name,
        "owner": ["login": "acme"],
        "default_branch": "main",
        "private": isPrivate,
    ]
}

private func rootSelection() throws -> RepositorySelection {
    try RepositorySelection(
        owner: "acme",
        name: "vault",
        branch: "main",
        storePath: ""
    )
}

private func snapshotPrelude(
    entries: [[String: Any]],
    truncated: Bool = false
) throws -> [HTTPResponse] {
    [
        try jsonResponse(["object": ["sha": "head-1"]]),
        try jsonResponse(["sha": "head-1", "tree": ["sha": "root-tree"]]),
        try treeResponse(sha: "root-tree", entries: entries, truncated: truncated),
    ]
}

private func compactStoreConfiguration() -> String {
    """
    schema_version = 1
    tasks_directory = "Tasks"
    projects_directory = "Projects"
    obsidian_link_prefix = "Vault"
    default_state = "open"

    [[states]]
    id = "open"
    name = "Open"
    terminal = false
    """
}

private func resourceBudget(
    maximumFallbackTreeRequests: Int = 8,
    maximumTreeDepth: Int = 8,
    maximumTreeEntries: Int = 32,
    maximumSelectedFiles: Int = 8,
    maximumRecordBytes: Int = 1_024,
    maximumConfigurationBytes: Int = 1_024,
    maximumAggregateBlobBytes: Int = 4_096
) -> GitHubResourceBudget {
    GitHubResourceBudget(
        maximumFallbackTreeRequests: maximumFallbackTreeRequests,
        maximumTreeDepth: maximumTreeDepth,
        maximumTreeEntries: maximumTreeEntries,
        maximumSelectedFiles: maximumSelectedFiles,
        maximumRecordBytes: maximumRecordBytes,
        maximumConfigurationBytes: maximumConfigurationBytes,
        maximumAggregateBlobBytes: maximumAggregateBlobBytes
    )
}

private func assertResourceLimitError(
    _ error: any Error,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let todoError = error as? OTodoError else {
        XCTFail("Expected a typed OTodoError, got \(error)", file: file, line: line)
        return
    }
    guard case .transport = todoError else {
        XCTFail("Expected a transport resource-limit error, got \(todoError)", file: file, line: line)
        return
    }
}

private func treeEntry(
    path: String,
    type: String,
    sha: String,
    size: Int? = nil
) -> [String: Any] {
    var entry: [String: Any] = [
        "path": path,
        "mode": type == "tree" ? "040000" : "100644",
        "type": type,
        "sha": sha,
    ]
    if let size {
        entry["size"] = size
    }
    return entry
}

private func jsonResponse(_ object: Any, statusCode: Int = 200) throws -> HTTPResponse {
    HTTPResponse(
        statusCode: statusCode,
        headers: ["Content-Type": "application/json"],
        body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

private func treeResponse(
    sha: String,
    entries: [[String: Any]],
    truncated: Bool = false
) throws -> HTTPResponse {
    try jsonResponse([
        "sha": sha,
        "tree": entries,
        "truncated": truncated,
    ])
}

private func blobResponse(_ content: String) throws -> HTTPResponse {
    try jsonResponse([
        "content": Data(content.utf8).base64EncodedString(),
        "encoding": "base64",
    ])
}
