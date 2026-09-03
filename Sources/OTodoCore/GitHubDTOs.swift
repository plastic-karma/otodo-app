import Foundation

struct GitHubAPIErrorDTO: Decodable {
    let message: String
    let documentationURL: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case documentationURL = "documentation_url"
    }
}

struct GitHubRepositoryDTO: Decodable {
    struct Owner: Decodable {
        let login: String
    }

    let name: String
    let owner: Owner
    let defaultBranch: String
    let isPrivate: Bool

    private enum CodingKeys: String, CodingKey {
        case name, owner
        case defaultBranch = "default_branch"
        case isPrivate = "private"
    }
}

struct GitHubReferenceDTO: Decodable {
    struct Object: Decodable {
        let sha: String
    }

    let object: Object
}

struct GitHubCommitDTO: Decodable {
    struct Tree: Decodable {
        let sha: String
    }

    let sha: String
    let tree: Tree
}

struct GitHubTreeEntryDTO: Decodable, Sendable {
    let path: String
    let mode: String
    let type: String
    let sha: String
    let size: Int?

    init(path: String, mode: String, type: String, sha: String, size: Int? = nil) {
        self.path = path
        self.mode = mode
        self.type = type
        self.sha = sha
        self.size = size
    }
}

struct GitHubTreeDTO: Decodable {
    let sha: String
    let tree: [GitHubTreeEntryDTO]
    let truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case sha, tree, truncated
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sha = try container.decode(String.self, forKey: .sha)
        tree = try container.decode([GitHubTreeEntryDTO].self, forKey: .tree)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

struct GitHubBlobDTO: Decodable {
    let content: String
    let encoding: String
}

struct GitHubCreatedObjectDTO: Decodable {
    let sha: String
}

struct GitHubCreateBlobRequestDTO: Encodable {
    let content: String
    let encoding = "utf-8"
}

struct GitHubCreateTreeRequestDTO: Encodable {
    let baseTree: String
    let tree: [GitHubCreateTreeEntryDTO]

    private enum CodingKeys: String, CodingKey {
        case baseTree = "base_tree"
        case tree
    }
}

struct GitHubCreateTreeEntryDTO: Encodable {
    let path: String
    let mode = "100644"
    let type = "blob"
    let sha: String?

    private enum CodingKeys: String, CodingKey {
        case path, mode, type, sha
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(mode, forKey: .mode)
        try container.encode(type, forKey: .type)
        if let sha {
            try container.encode(sha, forKey: .sha)
        } else {
            try container.encodeNil(forKey: .sha)
        }
    }
}

struct GitHubCreateCommitRequestDTO: Encodable {
    let message: String
    let tree: String
    let parents: [String]
}

struct GitHubUpdateReferenceRequestDTO: Encodable {
    let sha: String
    let force = false
}

struct OAuthDeviceCodeResponseDTO: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let expiresIn: TimeInterval
    let interval: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

struct OAuthTokenResponseDTO: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let tokenType: String?
    let scope: String?
    let expiresIn: TimeInterval?
    let refreshTokenExpiresIn: TimeInterval?
    let error: String?
    let errorDescription: String?
    let errorURI: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case error
        case errorDescription = "error_description"
        case errorURI = "error_uri"
    }
}
