import Foundation
import OTodoCore
import Security

enum KeychainCredentialStoreError: Error, Sendable, Equatable {
    enum Operation: String, Sendable, Equatable {
        case load
        case update
        case add
        case delete
    }

    case unexpectedStatus(operation: Operation, status: OSStatus)
    case invalidStoredCredential
    case credentialEncodingFailed
}

extension KeychainCredentialStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(operation, status):
            "Keychain \(operation.rawValue) failed with status \(status)"
        case .invalidStoredCredential:
            "The stored credential is not valid"
        case .credentialEncodingFailed:
            "The credential could not be encoded for secure storage"
        }
    }
}

actor KeychainCredentialStore: CredentialStoring {
    private let service: String
    private let account: String

    init(
        service: String = "plastickarma.otodo",
        account: String = "github-oauth-token-pair"
    ) {
        self.service = service
        self.account = account
    }

    func loadToken() async throws -> OAuthTokenPair? {
        var result: CFTypeRef?
        var query = scopedQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let token = try? JSONDecoder().decode(OAuthTokenPair.self, from: data)
            else {
                throw KeychainCredentialStoreError.invalidStoredCredential
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainCredentialStoreError.unexpectedStatus(operation: .load, status: status)
        }
    }

    func saveToken(_ token: OAuthTokenPair) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(token)
        } catch {
            throw KeychainCredentialStoreError.credentialEncodingFailed
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(scopedQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = scopedQuery
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess:
                return
            case errSecDuplicateItem:
                let retryStatus = SecItemUpdate(scopedQuery as CFDictionary, attributes as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw KeychainCredentialStoreError.unexpectedStatus(
                        operation: .update,
                        status: retryStatus
                    )
                }
            default:
                throw KeychainCredentialStoreError.unexpectedStatus(operation: .add, status: addStatus)
            }
        default:
            throw KeychainCredentialStoreError.unexpectedStatus(operation: .update, status: updateStatus)
        }
    }

    func clearToken() async throws {
        let status = SecItemDelete(scopedQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStoreError.unexpectedStatus(operation: .delete, status: status)
        }
    }

    private var scopedQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
