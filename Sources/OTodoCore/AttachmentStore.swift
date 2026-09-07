import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct AttachmentMetadata: Sendable, Codable, Equatable {
    /// Repository-relative path, matching Git tree entries.
    public let path: String
    public let blobSHA: String
    public let byteSize: Int
    public let isSymlink: Bool
    public let isDirectory: Bool
    public init(path: String, blobSHA: String, byteSize: Int, isSymlink: Bool = false, isDirectory: Bool = false) throws {
        try DomainValidation.validateRelativePath(path, field: "attachment.path")
        guard !blobSHA.isEmpty, byteSize >= 0 else {
            throw OTodoError.validation(field: "attachment", message: "SHA and nonnegative size are required")
        }
        self.path = path; self.blobSHA = blobSHA; self.byteSize = byteSize; self.isSymlink = isSymlink; self.isDirectory = isDirectory
    }
    private enum CodingKeys: String, CodingKey { case path, blobSHA, byteSize, isSymlink, isDirectory }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(path: c.decode(String.self, forKey: .path), blobSHA: c.decode(String.self, forKey: .blobSHA),
                      byteSize: c.decode(Int.self, forKey: .byteSize), isSymlink: c.decodeIfPresent(Bool.self, forKey: .isSymlink) ?? false,
                      isDirectory: c.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false)
    }
}

public struct BinaryFileReference: Sendable, Codable, Equatable {
    /// Relative to the repository-selection directory, never an absolute App Group path.
    public let localReference: String
    public let byteSize: Int
    public let blobSHA: String
    public init(localReference: String, byteSize: Int, blobSHA: String) throws {
        try DomainValidation.validateRelativePath(localReference, field: "attachment.localReference")
        guard localReference.hasPrefix("bytes/"), localReference.split(separator: "/").count == 2,
              byteSize >= 0, byteSize <= AttachmentLinks.maximumBytes,
              blobSHA.count == 40, blobSHA.allSatisfy({ $0.isHexDigit }) else {
            throw OTodoError.validation(field: "attachment", message: "Invalid bounded binary reference")
        }
        self.localReference = localReference; self.byteSize = byteSize; self.blobSHA = blobSHA
    }
    private enum CodingKeys: String, CodingKey { case localReference, byteSize, blobSHA }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(localReference: c.decode(String.self, forKey: .localReference),
                      byteSize: c.decode(Int.self, forKey: .byteSize), blobSHA: c.decode(String.self, forKey: .blobSHA))
    }
}

public struct AttachmentDraft: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let path: String
    public let displayName: String
    public let localFile: BinaryFileReference
    public var byteSize: Int { localFile.byteSize }
    public init(id: UUID = UUID(), path: String, displayName: String, localFile: BinaryFileReference) throws {
        try AttachmentLinks.validate(path: path)
        self.id = id; self.path = path; self.displayName = displayName; self.localFile = localFile
    }
}

public struct AttachmentCachedFile: Sendable, Equatable {
    public let url: URL
    public let blobSHA: String
    public let isOlderVersion: Bool
    public let isPinned: Bool
    public init(url: URL, blobSHA: String, isOlderVersion: Bool, isPinned: Bool) {
        self.url = url; self.blobSHA = blobSHA; self.isOlderVersion = isOlderVersion; self.isPinned = isPinned
    }
}

/// Immutable bytes are scoped by repository selection; workspace JSON holds only relative references.
public actor AttachmentStore {
    public static let maximumCacheBytes = 256 * 1_024 * 1_024
    private let rootURL: URL
    private let cacheBudget: Int
    private struct Entry: Codable {
        let path: String
        let file: BinaryFileReference
        var pinned: Bool
        var accessedAt: Date
    }

    public init(rootURL: URL, maximumCacheBytes: Int = AttachmentStore.maximumCacheBytes) {
        self.rootURL = rootURL.standardizedFileURL
        self.cacheBudget = maximumCacheBytes
    }

    public func stage(sourceURL: URL, selection: RepositorySelection) async throws -> AttachmentDraft {
        guard sourceURL.isFileURL else { throw OTodoError.validation(field: "attachment", message: "Select a local file") }
        try Self.rejectSymlinks(at: sourceURL)
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= AttachmentLinks.maximumBytes else {
            throw OTodoError.validation(field: "attachment", message: "Select a regular file no larger than 20 MiB")
        }
        let bytes = try Self.boundedData(at: sourceURL)
        return try await stage(data: bytes, filename: sourceURL.lastPathComponent, selection: selection)
    }

    public func stage(data: Data, filename: String, selection: RepositorySelection) async throws -> AttachmentDraft {
        guard data.count <= AttachmentLinks.maximumBytes else {
            throw OTodoError.validation(field: "attachment", message: "Attachments cannot exceed 20 MiB")
        }
        let name = AttachmentLinks.sanitizeFilename(filename)
        let id = try ULIDGenerator().generate(at: Date()).rawValue
        let path = "Attachments/\(id)/\(name)"
        let reference = try persist(data: data, selection: selection, filename: name)
        return try AttachmentDraft(path: path, displayName: name, localFile: reference)
    }

    public func read(_ reference: BinaryFileReference, selection: RepositorySelection) throws -> Data {
        let url = try Self.fileURL(rootURL: rootURL, reference: reference, selection: selection)
        let data = try Self.boundedData(at: url)
        guard data.count == reference.byteSize, GitBlobSHA.hexDigest(data) == reference.blobSHA else {
            throw OTodoError.corruptLocalState(message: "Attachment bytes do not match their saved Git SHA")
        }
        return data
    }

    public func localURL(_ reference: BinaryFileReference, selection: RepositorySelection) throws -> URL {
        _ = try read(reference, selection: selection)
        return try Self.fileURL(rootURL: rootURL, reference: reference, selection: selection)
    }

    public func cachedFile(path: String, selection: RepositorySelection, expectedSHA: String? = nil) throws -> AttachmentCachedFile? {
        try AttachmentDiskLock.withLock(rootURL: rootURL) {
            guard var entry = try loadEntry(path: path, selection: selection) else { return nil }
            let url = try localURL(entry.file, selection: selection)
            entry.accessedAt = Date()
            try saveEntry(entry, selection: selection)
            return AttachmentCachedFile(url: url, blobSHA: entry.file.blobSHA,
                isOlderVersion: expectedSHA.map { $0 != entry.file.blobSHA } ?? false, isPinned: entry.pinned)
        }
    }

    @discardableResult
    public func download(attachment: AttachmentMetadata, selection: RepositorySelection, gitHub: any GitHubServing) async throws -> AttachmentCachedFile {
        guard !attachment.isSymlink, !attachment.isDirectory, attachment.byteSize <= AttachmentLinks.maximumBytes else {
            throw OTodoError.validation(field: "attachment", message: "Select a regular attachment file no larger than 20 MiB")
        }
        if let cached = try cachedFile(path: attachment.path, selection: selection, expectedSHA: attachment.blobSHA), !cached.isOlderVersion { return cached }
        let bytes = try await gitHub.fetchAttachment(selection: selection, attachment: attachment)
        guard bytes.count <= AttachmentLinks.maximumBytes, bytes.count == attachment.byteSize,
              GitBlobSHA.hexDigest(bytes) == attachment.blobSHA else {
            throw OTodoError.transport(statusCode: nil, message: "Downloaded attachment does not match the catalogued size and Git SHA")
        }
        let reference = try persist(data: bytes, selection: selection, filename: (attachment.path as NSString).lastPathComponent)
        try await retainVerified(reference, path: attachment.path, selection: selection)
        guard let cached = try cachedFile(path: attachment.path, selection: selection, expectedSHA: attachment.blobSHA) else {
            throw OTodoError.notFound(resource: "Attachment was evicted from the local cache; download again")
        }
        return cached
    }

    public func retainVerified(_ reference: BinaryFileReference, path: String, selection: RepositorySelection) async throws {
        let previous = try AttachmentDiskLock.withLock(rootURL: rootURL) {
            _ = try read(reference, selection: selection)
            let previous = try loadEntry(path: path, selection: selection)
            try saveEntry(Entry(path: path, file: reference, pinned: previous?.pinned ?? false, accessedAt: Date()), selection: selection)
            return previous
        }
        if let previous, previous.file != reference {
            try await FileWorkspaceStore(rootURL: rootURL).discardUnreferencedAttachment(previous.file, selection: selection)
        }
    }

    public func setPinned(path: String, selection: RepositorySelection, pinned: Bool) throws {
        try AttachmentDiskLock.withLock(rootURL: rootURL) {
            guard var entry = try loadEntry(path: path, selection: selection) else {
                throw OTodoError.notFound(resource: "Download this attachment before keeping it offline")
            }
            entry.pinned = pinned
            try saveEntry(entry, selection: selection)
        }
    }

    /// Failed replacements retain the prior file and its pin. Returned errors belong to attachments, not task sync.
    public func refreshPinned(attachments: [AttachmentMetadata], selection: RepositorySelection, gitHub: any GitHubServing) async -> [String: String] {
        var failures: [String: String] = [:]
        do {
            let catalog = Dictionary(uniqueKeysWithValues: attachments.map { ($0.path, $0) })
            let cached = try AttachmentDiskLock.withLock(rootURL: rootURL) { try entries(selection: selection) }
            for entry in cached where entry.pinned {
                guard let remote = catalog[entry.path] else { failures[entry.path] = "Attachment is missing remotely; retained offline version"; continue }
                do { _ = try await download(attachment: remote, selection: selection, gitHub: gitHub) }
                catch { failures[entry.path] = error.localizedDescription }
            }
        } catch { failures["cache"] = error.localizedDescription }
        return failures
    }

    public func discard(drafts: [AttachmentDraft], selection: RepositorySelection, persistence: any WorkspacePersisting) async throws {
        // The file-backed implementation checks durable references and deletes under its save lock.
        // Unknown persistence implementations retain bytes conservatively.
        guard let files = persistence as? FileWorkspaceStore else { return }
        for draft in drafts { try await files.discardUnreferencedAttachment(draft.localFile, selection: selection) }
    }

    public func evict(selection: RepositorySelection, workspace: WorkspaceState) async throws {
        let protected = Set(workspace.pendingChanges.compactMap { $0.payload.binaryFile?.localReference }
            + workspace.conflicts.flatMap { [$0.localPayload.binaryFile?.localReference, $0.remotePayload.binaryFile?.localReference].compactMap { $0 } })
        let cached = try AttachmentDiskLock.withLock(rootURL: rootURL) { try entries(selection: selection) }
        var total = cached.reduce(0) { $0 + $1.file.byteSize }
        for entry in cached.sorted(by: { $0.accessedAt < $1.accessedAt }) where total > cacheBudget {
            guard !entry.pinned, !protected.contains(entry.file.localReference) else { continue }
            let removed = try AttachmentDiskLock.withLock(rootURL: rootURL) {
                guard let current = try loadEntry(path: entry.path, selection: selection), !current.pinned,
                      current.file == entry.file, current.accessedAt == entry.accessedAt else { return false }
                try FileManager.default.removeItem(at: entryURL(path: entry.path, selection: selection))
                return true
            }
            if removed {
                try await FileWorkspaceStore(rootURL: rootURL).discardUnreferencedAttachment(entry.file, selection: selection)
                total -= entry.file.byteSize
            }
        }
    }

    private func persist(data: Data, selection: RepositorySelection, filename: String) throws -> BinaryFileReference {
        let reference = try BinaryFileReference(localReference: "bytes/\(UUID().uuidString)-\(AttachmentLinks.sanitizeFilename(filename))", byteSize: data.count, blobSHA: GitBlobSHA.hexDigest(data))
        let directory = Self.selectionURL(rootURL: rootURL, selection: selection).appendingPathComponent("bytes", isDirectory: true)
        try Self.rejectSymlinks(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try Self.fileURL(rootURL: rootURL, reference: reference, selection: selection)
        try data.write(to: url, options: .withoutOverwriting)
        try FileWorkspaceStore.setPermissions(0o600, at: url)
        return reference
    }
    private func entryURL(path: String, selection: RepositorySelection) -> URL {
        Self.selectionURL(rootURL: rootURL, selection: selection).appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(GitBlobSHA.hexDigest(Data(path.utf8)) + ".json")
    }
    private func loadEntry(path: String, selection: RepositorySelection) throws -> Entry? {
        let url = entryURL(path: path, selection: selection)
        try Self.rejectSymlinks(at: url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
    }
    private func saveEntry(_ entry: Entry, selection: RepositorySelection) throws {
        let url = entryURL(path: entry.path, selection: selection)
        try Self.rejectSymlinks(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: url, options: .atomic)
    }
    private func entries(selection: RepositorySelection) throws -> [Entry] {
        let directory = Self.selectionURL(rootURL: rootURL, selection: selection).appendingPathComponent("cache")
        try Self.rejectSymlinks(at: directory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map {
                try Self.rejectSymlinks(at: $0)
                return try JSONDecoder().decode(Entry.self, from: Data(contentsOf: $0))
            }
    }
    nonisolated static func selectionURL(rootURL: URL, selection: RepositorySelection) -> URL {
        rootURL.appendingPathComponent("attachment-files", isDirectory: true)
            .appendingPathComponent(FileWorkspaceStore.selectionKey(for: selection), isDirectory: true)
    }
    nonisolated static func fileURL(rootURL: URL, reference: BinaryFileReference, selection: RepositorySelection) throws -> URL {
        let url = selectionURL(rootURL: rootURL, selection: selection).appendingPathComponent(reference.localReference)
        try rejectSymlinks(at: url)
        return url
    }
    nonisolated static func rejectSymlinks(at url: URL) throws {
        guard url.isFileURL else { throw OTodoError.validation(field: "attachment", message: "A local file URL is required") }
        var current = url.standardizedFileURL
        while current.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                #if canImport(Darwin)
                // Apple supplies container URLs through these fixed OS aliases, including test temporary roots.
                if ["/var", "/tmp"].contains(current.path),
                   ["private" + current.path, "/private" + current.path].contains((try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) ?? "") {
                    current.deleteLastPathComponent()
                    continue
                }
                #endif
                throw OTodoError.validation(field: "attachment", message: "Symbolic links are not allowed")
            }
            current.deleteLastPathComponent()
        }
    }
    private nonisolated static func boundedData(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: AttachmentLinks.maximumBytes + 1) ?? Data()
        guard data.count <= AttachmentLinks.maximumBytes else {
            throw OTodoError.validation(field: "attachment", message: "Attachment exceeds 20 MiB")
        }
        return data
    }
}

/// Process-local plus cross-process locking protects cache pins and immutable-file reference cleanup.
enum AttachmentDiskLock {
    private static let local = NSLock()
    static func withLock<Value>(rootURL: URL, body: () throws -> Value) throws -> Value {
        try local.withLock {
            try AttachmentStore.rejectSymlinks(at: rootURL)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            #if canImport(Darwin) || canImport(Glibc)
            let url = rootURL.appendingPathComponent(".attachments.lock")
            try AttachmentStore.rejectSymlinks(at: url)
            let descriptor = url.path.withCString { open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
            guard descriptor >= 0 else { throw OTodoError.corruptLocalState(message: "Could not open attachment cache lock") }
            defer { _ = close(descriptor) }
            guard lockf(descriptor, F_LOCK, 0) == 0 else { throw OTodoError.corruptLocalState(message: "Could not lock attachment cache") }
            #endif
            return try body()
        }
    }
}

/// Git blob object identity, including the mandatory blob header (SHA-1 repositories).
public enum GitBlobSHA {
    public static func hexDigest(_ data: Data) -> String {
        var bytes = Array("blob \(data.count)\u{0}".utf8) + data
        let bits = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bits >> shift)) }
        var h: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]
        func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
        for start in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 { let j = start + i * 4; w[i] = UInt32(bytes[j]) << 24 | UInt32(bytes[j + 1]) << 16 | UInt32(bytes[j + 2]) << 8 | UInt32(bytes[j + 3]) }
            for i in 16..<80 { w[i] = rotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i { case 0..<20: f = (b & c) | (~b & d); k = 0x5a827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ed9eba1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc
                default: f = b ^ c ^ d; k = 0xca62c1d6 }
                let t = rotate(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotate(b, 30); b = a; a = t
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
