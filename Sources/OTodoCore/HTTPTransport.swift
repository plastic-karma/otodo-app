import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A transport-neutral HTTP response suitable for deterministic client tests.
public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// The sole networking boundary used by the GitHub clients.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// URLSession-backed production transport. Status handling remains the client's responsibility.
public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    public static let defaultMaximumResponseBodyBytes = 16 * 1_024 * 1_024

    private let session: URLSession
    private let maximumResponseBodyBytes: Int

    public init(
        session: URLSession = .shared,
        maximumResponseBodyBytes: Int = URLSessionHTTPTransport.defaultMaximumResponseBodyBytes
    ) {
        precondition(maximumResponseBodyBytes >= 0, "The HTTP response byte limit cannot be negative")
        self.session = session
        self.maximumResponseBodyBytes = maximumResponseBodyBytes
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
#if canImport(FoundationNetworking)
            // swift-corelibs-foundation does not expose URLSession.AsyncBytes. Keep the
            // same hard retained-body bound even though this platform must receive the
            // response before checking it.
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw OTodoError.transport(statusCode: nil, message: "The server returned a non-HTTP response")
            }
            try validateBodySize(data.count, response: response)
            return HTTPResponse(
                statusCode: response.statusCode,
                headers: responseHeaders(response),
                body: data
            )
#else
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw OTodoError.transport(statusCode: nil, message: "The server returned a non-HTTP response")
            }
            if response.expectedContentLength > Int64(maximumResponseBodyBytes) {
                throw responseTooLarge(response)
            }

            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumResponseBodyBytes else {
                    throw responseTooLarge(response)
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            return HTTPResponse(
                statusCode: response.statusCode,
                headers: responseHeaders(response),
                body: data
            )
#endif
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OTodoError {
            throw error
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw OTodoError.transport(statusCode: nil, message: error.localizedDescription)
        }
    }

    private func validateBodySize(_ count: Int, response: HTTPURLResponse) throws {
        guard count <= maximumResponseBodyBytes else {
            throw responseTooLarge(response)
        }
    }

    private func responseTooLarge(_ response: HTTPURLResponse) -> OTodoError {
        OTodoError.transport(
            statusCode: response.statusCode,
            message: "The HTTP response exceeded the \(maximumResponseBodyBytes)-byte limit"
        )
    }

    private func responseHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        headers.reserveCapacity(response.allHeaderFields.count)
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key] = String(describing: value)
        }
        return headers
    }
}
