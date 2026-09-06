import Foundation
import OTodoCore

enum WatchSnapshotStorage {
    static let contextKey = "snapshot"
    static let requestKey = "requestSnapshot"
    static let widgetKind = "OTodoWatchToday"

    static var directoryURL: URL {
        get throws {
            try SharedWorkspaceStorage.directoryURL()
                .appendingPathComponent("watch-snapshot", isDirectory: true)
        }
    }

    static func load() throws -> WatchWorkspaceSnapshot? {
        let fileURL = try directoryURL.appendingPathComponent("snapshot.json")
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(WatchWorkspaceSnapshot.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// The caller validates the envelope before saving its original encoded bytes.
    static func save(data: Data) throws {
        let directory = try directoryURL
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
    }
}
