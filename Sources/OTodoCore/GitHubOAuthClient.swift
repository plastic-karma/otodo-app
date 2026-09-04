import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class GitHubOAuthClient: Sendable {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let clientID: String
    private let transport: any HTTPTransport
    private let baseURL: URL
    private let now: @Sendable () -> Date
    private let sleep: Sleep

    public init(
        clientID: String,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        baseURL: URL = URL(string: "https://github.com")!,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Sleep = { seconds in
            guard seconds > 0, seconds.isFinite else { return }
            let nanoseconds = UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.clientID = clientID
        self.transport = transport
        self.baseURL = baseURL
        self.now = now
        self.sleep = sleep
    }

    /// Starts GitHub's secretless Device Authorization flow, requesting private repository access.
    public func startDeviceFlow() async throws -> OAuthDeviceCode {
        try Task.checkCancellation()
        guard !clientID.isEmpty else {
            throw OTodoError.authentication(message: "A GitHub OAuth client ID is required")
        }

        let response = try await sendForm(
            endpoint: "login/device/code",
            fields: ["client_id": clientID, "scope": "repo"]
        )
        guard (200..<300).contains(response.statusCode) else {
            throw oauthHTTPError(response, context: "starting device authorization")
        }
        if let oauthError = try? JSONDecoder().decode(OAuthTokenResponseDTO.self, from: response.body),
           oauthError.error != nil
        {
            throw OTodoError.authentication(
                message: oauthMessage(oauthError, fallback: "GitHub rejected the device authorization request")
            )
        }

        let wire: OAuthDeviceCodeResponseDTO
        do {
            wire = try JSONDecoder().decode(OAuthDeviceCodeResponseDTO.self, from: response.body)
        } catch {
            throw OTodoError.transport(
                statusCode: response.statusCode,
                message: "GitHub returned an invalid device authorization response: \(error.localizedDescription)"
            )
        }

        guard !wire.deviceCode.isEmpty, !wire.userCode.isEmpty else {
            throw OTodoError.authentication(message: "GitHub returned an empty device or user code")
        }
        guard let verificationURI = URL(string: wire.verificationURI),
              verificationURI.scheme == "https" || verificationURI.scheme == "http"
        else {
            throw OTodoError.transport(
                statusCode: response.statusCode,
                message: "GitHub returned an invalid device verification URL"
            )
        }
        guard wire.expiresIn > 0, wire.expiresIn.isFinite,
              wire.interval > 0, wire.interval.isFinite
        else {
            throw OTodoError.transport(
                statusCode: response.statusCode,
                message: "GitHub returned invalid device authorization timing values"
            )
        }

        let receivedAt = now()
        return OAuthDeviceCode(
            deviceCode: wire.deviceCode,
            userCode: wire.userCode,
            verificationURI: verificationURI,
            expiresAt: receivedAt.addingTimeInterval(wire.expiresIn),
            pollingInterval: wire.interval
        )
    }

    /// Polls at GitHub's requested interval until authorization succeeds or reaches a terminal state.
    public func pollForToken(deviceCode: OAuthDeviceCode) async throws -> OAuthTokenPair {
        guard !clientID.isEmpty else {
            throw OTodoError.authentication(message: "A GitHub OAuth client ID is required")
        }
        guard !deviceCode.deviceCode.isEmpty,
              deviceCode.pollingInterval > 0,
              deviceCode.pollingInterval.isFinite
        else {
            throw OTodoError.authentication(message: "The device authorization is invalid")
        }

        var interval = deviceCode.pollingInterval
        while true {
            try Task.checkCancellation()
            guard now() < deviceCode.expiresAt else {
                throw OTodoError.authentication(message: "The GitHub device authorization expired")
            }

            try await sleep(interval)
            try Task.checkCancellation()
            guard now() < deviceCode.expiresAt else {
                throw OTodoError.authentication(message: "The GitHub device authorization expired")
            }

            let response: HTTPResponse
            do {
                response = try await sendForm(
                    endpoint: "login/oauth/access_token",
                    fields: [
                        "client_id": clientID,
                        "device_code": deviceCode.deviceCode,
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    ]
                )
            } catch let error as OTodoError {
                guard case .transport(nil, _) = error else {
                    throw error
                }
                // Opening GitHub backgrounds the app and can interrupt an in-flight
                // poll. The device code remains valid, so retry after the next interval.
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                throw oauthHTTPError(response, context: "polling device authorization")
            }

            let wire = try decodeTokenResponse(response, context: "polling device authorization")
            if let error = wire.error {
                switch error {
                case "authorization_pending":
                    continue
                case "slow_down":
                    interval += 5
                    continue
                case "expired_token":
                    throw OTodoError.authentication(message: oauthMessage(wire, fallback: "The GitHub device authorization expired"))
                case "access_denied":
                    throw OTodoError.authentication(message: oauthMessage(wire, fallback: "GitHub device authorization was denied"))
                case "device_flow_disabled":
                    throw OTodoError.authentication(message: oauthMessage(wire, fallback: "GitHub Device Flow is disabled for this OAuth app"))
                default:
                    throw OTodoError.authentication(message: oauthMessage(wire, fallback: "GitHub OAuth error: \(error)"))
                }
            }

            return try makeToken(from: wire, receivedAt: now(), replacing: nil)
        }
    }

    /// Exchanges a refresh token without a client secret and atomically returns all rotated values.
    public func refreshToken(_ currentToken: OAuthTokenPair) async throws -> OAuthTokenPair {
        try Task.checkCancellation()
        guard !clientID.isEmpty else {
            throw OTodoError.authentication(message: "A GitHub OAuth client ID is required")
        }
        guard let refreshToken = currentToken.refreshToken, !refreshToken.isEmpty else {
            throw OTodoError.authentication(message: "No GitHub refresh token is available")
        }

        let response = try await sendForm(
            endpoint: "login/oauth/access_token",
            fields: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ]
        )
        guard (200..<300).contains(response.statusCode) else {
            throw oauthHTTPError(response, context: "refreshing authorization")
        }

        let wire = try decodeTokenResponse(response, context: "refreshing authorization")
        if wire.error != nil {
            throw OTodoError.authentication(
                message: oauthMessage(wire, fallback: "GitHub rejected the refresh token")
            )
        }
        return try makeToken(from: wire, receivedAt: now(), replacing: currentToken)
    }

    private func sendForm(endpoint: String, fields: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: try endpointURL(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("OTodo/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(formEncode(fields).utf8)
        return try await transport.send(request)
    }

    private func endpointURL(_ endpoint: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil
        else {
            throw OTodoError.transport(statusCode: nil, message: "Invalid GitHub OAuth base URL")
        }
        let prefix = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + ([prefix, endpoint].filter { !$0.isEmpty }.joined(separator: "/"))
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw OTodoError.transport(statusCode: nil, message: "Could not construct a GitHub OAuth URL")
        }
        return url
    }

    private func formEncode(_ fields: [String: String]) -> String {
        fields.keys.sorted().map { key in
            "\(formComponent(key))=\(formComponent(fields[key]!))"
        }.joined(separator: "&")
    }

    private func formComponent(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                result.unicodeScalars.append(UnicodeScalar(byte))
            case 0x20:
                result.append("+")
            default:
                result.append(String(format: "%%%02X", byte))
            }
        }
        return result
    }

    private func decodeTokenResponse(_ response: HTTPResponse, context: String) throws -> OAuthTokenResponseDTO {
        do {
            return try JSONDecoder().decode(OAuthTokenResponseDTO.self, from: response.body)
        } catch {
            throw OTodoError.transport(
                statusCode: response.statusCode,
                message: "GitHub returned an invalid OAuth response while \(context): \(error.localizedDescription)"
            )
        }
    }

    private func makeToken(
        from wire: OAuthTokenResponseDTO,
        receivedAt: Date,
        replacing current: OAuthTokenPair?
    ) throws -> OAuthTokenPair {
        guard let accessToken = wire.accessToken, !accessToken.isEmpty else {
            throw OTodoError.authentication(message: "GitHub returned no access token")
        }
        guard let tokenType = wire.tokenType, !tokenType.isEmpty else {
            throw OTodoError.authentication(message: "GitHub returned no token type")
        }

        if let expiresIn = wire.expiresIn, !(expiresIn > 0 && expiresIn.isFinite) {
            throw OTodoError.transport(statusCode: 200, message: "GitHub returned an invalid access-token expiry")
        }
        if let expiresIn = wire.refreshTokenExpiresIn, !(expiresIn > 0 && expiresIn.isFinite) {
            throw OTodoError.transport(statusCode: 200, message: "GitHub returned an invalid refresh-token expiry")
        }

        let refreshToken = wire.refreshToken ?? current?.refreshToken
        let refreshExpiresAt: Date?
        if let expiresIn = wire.refreshTokenExpiresIn {
            refreshExpiresAt = receivedAt.addingTimeInterval(expiresIn)
        } else if wire.refreshToken != nil {
            refreshExpiresAt = nil
        } else {
            refreshExpiresAt = current?.refreshTokenExpiresAt
        }

        return OAuthTokenPair(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            scope: wire.scope ?? current?.scope,
            accessTokenExpiresAt: wire.expiresIn.map { receivedAt.addingTimeInterval($0) },
            refreshTokenExpiresAt: refreshExpiresAt
        )
    }

    private func oauthHTTPError(_ response: HTTPResponse, context: String) -> OTodoError {
        if let wire = try? JSONDecoder().decode(OAuthTokenResponseDTO.self, from: response.body),
           wire.error != nil
        {
            return .authentication(message: oauthMessage(wire, fallback: "GitHub rejected the OAuth request"))
        }
        if let wire = try? JSONDecoder().decode(GitHubAPIErrorDTO.self, from: response.body) {
            return .transport(statusCode: response.statusCode, message: "GitHub failed while \(context): \(wire.message)")
        }
        return .transport(statusCode: response.statusCode, message: "GitHub failed while \(context)")
    }

    private func oauthMessage(_ wire: OAuthTokenResponseDTO, fallback: String) -> String {
        if let description = wire.errorDescription, !description.isEmpty {
            return description
        }
        return fallback
    }

}
