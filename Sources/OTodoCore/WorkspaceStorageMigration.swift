import Foundation

public enum WorkspaceStorageMigration {
    /// Moves the complete legacy directory before any store starts using the new location.
    /// Existing shared data is authoritative and is never replaced by an older private cache.
    public static func prepare(legacyURL: URL, destinationURL: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw OTodoError.corruptLocalState(message: "The shared workspace location is not a directory")
            }
            return
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if fileManager.fileExists(atPath: legacyURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw OTodoError.corruptLocalState(message: "The legacy workspace location is not a directory")
            }
            // Both iOS containers are on the data volume. Rename publishes workspaces,
            // outbox, filters, and repository selection together, without copying or
            // exposing a partially migrated directory. A failure leaves the source intact.
            #if canImport(Darwin) || canImport(Glibc)
            try FileWorkspaceStore.atomicallyReplaceItem(
                at: destinationURL,
                withItemAt: legacyURL,
                fileManager: fileManager
            )
            #else
            try fileManager.moveItem(at: legacyURL, to: destinationURL)
            #endif
        } else {
            try fileManager.createDirectory(
                at: destinationURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}
