import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Persists each selected repository workspace as one versioned JSON document.
public actor FileWorkspaceStore: WorkspacePersisting {
    private static let formatVersion = 2
    private static let persistenceLock = NSLock()

    private struct Envelope: Codable {
        let version: Int
        let workspace: WorkspaceState

        private enum CodingKeys: String, CodingKey { case version, workspace }

        init(version: Int, workspace: WorkspaceState) {
            self.version = version
            self.workspace = workspace
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            guard version == 1 || version == 2 else {
                throw OTodoError.corruptLocalState(message: "Unsupported workspace persistence version \(version)")
            }
            let decoded = try container.decode(WorkspaceState.self, forKey: .workspace)
            workspace = try decoded.importCacheRecords(legacyEnvelope: version == 1)
        }
    }

    private let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func load(selection: RepositorySelection) async throws -> WorkspaceState? {
        try requireFileRoot()
        let url = workspaceURL(for: selection)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let envelope = try Self.decoder().decode(Envelope.self, from: data)
            guard envelope.version == 1 || envelope.version == Self.formatVersion else {
                throw OTodoError.corruptLocalState(
                    message: "Unsupported workspace persistence version \(envelope.version)"
                )
            }
            guard envelope.workspace.selection == selection else {
                throw OTodoError.corruptLocalState(
                    message: "Workspace selection does not match its persistence key"
                )
            }
            return envelope.workspace
        } catch let error as OTodoError {
            if case .corruptLocalState = error {
                throw error
            }
            throw OTodoError.corruptLocalState(
                message: "Workspace contains invalid persisted data: \(error.localizedDescription)"
            )
        } catch {
            throw OTodoError.corruptLocalState(
                message: "Could not read workspace \(Self.selectionKey(for: selection)): \(error.localizedDescription)"
            )
        }
    }

    public func save(
        _ workspace: WorkspaceState,
        expectedRevision: UInt64?
    ) async throws {
        try requireFileRoot()

        let envelope = Envelope(version: Self.formatVersion, workspace: workspace)
        let data: Data
        do {
            data = try Self.encoder().encode(envelope)
            // Encoding bypasses validating Codable initializers. Decode before touching disk so
            // a caller cannot persist a value mutated into an invalid domain state.
            _ = try Self.decoder().decode(Envelope.self, from: data)
        } catch let error as OTodoError {
            throw error
        } catch {
            throw OTodoError.corruptLocalState(
                message: "Workspace could not be encoded as valid local state: \(error.localizedDescription)"
            )
        }

        try Self.persistenceLock.withLock {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try Self.setPermissions(0o700, at: rootURL)
            } catch {
                throw OTodoError.corruptLocalState(
                    message: "Could not prepare workspace directory: \(error.localizedDescription)"
                )
            }

            #if canImport(Darwin) || canImport(Glibc)
            // Lock a stable file, not the JSON inode replaced by the atomic rename below.
            // The process-local lock also serializes stores because POSIX record locks
            // are owned by the process rather than by an individual file descriptor.
            let lockDescriptor = try acquireWorkspaceLock()
            defer { _ = close(lockDescriptor) }
            #endif

            let destinationURL = workspaceURL(for: workspace.selection)
            let destinationExists = fileManager.fileExists(atPath: destinationURL.path)

            switch expectedRevision {
            case let expected?:
                guard destinationExists else {
                    throw OTodoError.conflict(
                        message: "Workspace revision \(expected) no longer exists"
                    )
                }
                let persisted = try loadPersistedWorkspace(
                    at: destinationURL,
                    selection: workspace.selection
                )
                guard persisted.revision == expected else {
                    throw OTodoError.conflict(
                        message: "Workspace revision changed from \(expected) to \(persisted.revision)"
                    )
                }
                guard expected < UInt64.max, workspace.revision == expected + 1 else {
                    throw OTodoError.corruptLocalState(
                        message: "Workspace revision must increase exactly once from \(expected)"
                    )
                }

            case nil:
                guard !destinationExists else {
                    throw OTodoError.conflict(message: "Workspace already exists")
                }
                guard workspace.revision == 0 else {
                    throw OTodoError.corruptLocalState(
                        message: "A new workspace must start at revision 0"
                    )
                }
            }

            do {
                let temporaryURL = rootURL.appendingPathComponent(
                    ".\(Self.selectionKey(for: workspace.selection)).\(UUID().uuidString).tmp",
                    isDirectory: false
                )
                defer { try? fileManager.removeItem(at: temporaryURL) }

                try data.write(to: temporaryURL, options: .withoutOverwriting)
                try Self.setPermissions(0o600, at: temporaryURL)

                if destinationExists {
                    try Self.atomicallyReplaceItem(
                        at: destinationURL,
                        withItemAt: temporaryURL,
                        fileManager: fileManager
                    )
                } else {
                    try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                }
                try Self.setPermissions(0o600, at: destinationURL)
            } catch let error as OTodoError {
                throw error
            } catch {
                throw OTodoError.corruptLocalState(
                    message: "Could not atomically save workspace: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Stable, filesystem-safe key derived from all normalized selection fields.
    public nonisolated static func selectionKey(for selection: RepositorySelection) -> String {
        var bytes = [UInt8]()
        for component in [selection.owner, selection.name, selection.branch, selection.storePath] {
            let componentBytes = Array(component.utf8)
            bytes.append(contentsOf: String(componentBytes.count).utf8)
            bytes.append(58)
            bytes.append(contentsOf: componentBytes)
        }
        return SHA256.hexDigest(bytes)
    }

    private func workspaceURL(for selection: RepositorySelection) -> URL {
        rootURL.appendingPathComponent(
            "\(Self.selectionKey(for: selection)).json",
            isDirectory: false
        )
    }

    private func requireFileRoot() throws {
        guard rootURL.isFileURL else {
            throw OTodoError.corruptLocalState(message: "Workspace root must be a file URL")
        }
    }

    #if canImport(Darwin) || canImport(Glibc)
    private func acquireWorkspaceLock() throws -> Int32 {
        let lockURL = rootURL.appendingPathComponent(".workspace.lock", isDirectory: false)
        do {
            let descriptor = try lockURL.withUnsafeFileSystemRepresentation { path in
                guard let path else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
                }
                let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
                guard descriptor >= 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                return descriptor
            }
            do {
                guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                // A fresh descriptor starts at offset zero; length zero locks through EOF.
                // Closing it releases the lock on both successful and failed transactions.
                guard lockf(descriptor, F_LOCK, 0) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                return descriptor
            } catch {
                _ = close(descriptor)
                throw error
            }
        } catch {
            throw OTodoError.corruptLocalState(
                message: "Could not lock workspace for saving: \(error.localizedDescription)"
            )
        }
    }
    #endif

    private func loadPersistedWorkspace(
        at url: URL,
        selection: RepositorySelection
    ) throws -> WorkspaceState {
        do {
            let data = try Data(contentsOf: url)
            let envelope = try Self.decoder().decode(Envelope.self, from: data)
            guard envelope.version == 1 || envelope.version == Self.formatVersion else {
                throw OTodoError.corruptLocalState(
                    message: "Unsupported workspace persistence version \(envelope.version)"
                )
            }
            guard envelope.workspace.selection == selection else {
                throw OTodoError.corruptLocalState(
                    message: "Workspace selection does not match its persistence key"
                )
            }
            return envelope.workspace
        } catch let error as OTodoError {
            if case .corruptLocalState = error {
                throw error
            }
            throw OTodoError.corruptLocalState(
                message: "Workspace contains invalid persisted data: \(error.localizedDescription)"
            )
        } catch {
            throw OTodoError.corruptLocalState(
                message: "Could not read workspace \(Self.selectionKey(for: selection)): \(error.localizedDescription)"
            )
        }
    }

    nonisolated static func atomicallyReplaceItem(
        at destinationURL: URL,
        withItemAt temporaryURL: URL,
        fileManager: FileManager
    ) throws {
        #if canImport(Darwin) || canImport(Glibc)
        var renameError: Int32?
        temporaryURL.withUnsafeFileSystemRepresentation { temporaryPath in
            guard let temporaryPath else {
                renameError = EINVAL
                return
            }
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let destinationPath else {
                    renameError = EINVAL
                    return
                }

                #if canImport(Darwin)
                let result = Darwin.rename(temporaryPath, destinationPath)
                #else
                let result = Glibc.rename(temporaryPath, destinationPath)
                #endif
                if result != 0 {
                    renameError = errno
                }
            }
        }

        if let renameError {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(renameError),
                userInfo: [NSFilePathErrorKey: destinationURL.path]
            )
        }
        #else
        _ = try fileManager.replaceItemAt(
            destinationURL,
            withItemAt: temporaryURL,
            backupItemName: nil,
            options: .usingNewMetadataOnly
        )
        #endif
    }

    private nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private nonisolated static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    nonisolated static func setPermissions(_ permissions: Int, at url: URL) throws {
        #if os(Windows)
        _ = permissions
        _ = url
        #else
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
        #endif
    }
}

private enum SHA256 {
    private static let initialHash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hexDigest(_ input: [UInt8]) -> String {
        let digest = digest(input)
        let alphabet = Array("0123456789abcdef".utf8)
        var result = [UInt8]()
        result.reserveCapacity(digest.count * 2)
        for byte in digest {
            result.append(alphabet[Int(byte >> 4)])
            result.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func digest(_ input: [UInt8]) -> [UInt8] {
        var message = input
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var hash = initialHash
        var words = [UInt32](repeating: 0, count: 64)
        for blockStart in stride(from: 0, to: message.count, by: 64) {
            for index in 0 ..< 16 {
                let offset = blockStart + index * 4
                words[index] = UInt32(message[offset]) << 24
                    | UInt32(message[offset + 1]) << 16
                    | UInt32(message[offset + 2]) << 8
                    | UInt32(message[offset + 3])
            }
            for index in 16 ..< 64 {
                let x = words[index - 15]
                let y = words[index - 2]
                let sigma0 = rotateRight(x, by: 7) ^ rotateRight(x, by: 18) ^ (x >> 3)
                let sigma1 = rotateRight(y, by: 17) ^ rotateRight(y, by: 19) ^ (y >> 10)
                words[index] = words[index - 16] &+ sigma0 &+ words[index - 7] &+ sigma1
            }

            var a = hash[0]
            var b = hash[1]
            var c = hash[2]
            var d = hash[3]
            var e = hash[4]
            var f = hash[5]
            var g = hash[6]
            var h = hash[7]

            for index in 0 ..< 64 {
                let sum1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choice = (e & f) ^ ((~e) & g)
                let temporary1 = h &+ sum1 &+ choice &+ constants[index] &+ words[index]
                let sum0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temporary2 = sum0 &+ majority

                h = g
                g = f
                f = e
                e = d &+ temporary1
                d = c
                c = b
                b = a
                a = temporary1 &+ temporary2
            }

            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
        }

        var output = [UInt8]()
        output.reserveCapacity(32)
        for word in hash {
            output.append(UInt8(truncatingIfNeeded: word >> 24))
            output.append(UInt8(truncatingIfNeeded: word >> 16))
            output.append(UInt8(truncatingIfNeeded: word >> 8))
            output.append(UInt8(truncatingIfNeeded: word))
        }
        return output
    }

    private static func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
