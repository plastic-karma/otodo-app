import Foundation
import OTodoCore

/// The app, Share extension, and App Intent use one selected workspace and outbox.
enum SharedWorkspaceStorage {
    static let appGroupIdentifier = "group.plastickarma.otodo"

    private static func containerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw OTodoError.corruptLocalState(
                message: "The shared OTodo container is unavailable. Open a correctly signed build of OTodo and try again."
            )
        }
        return url
    }

    static func directoryURL() throws -> URL {
        let container = try containerURL()
        #if DEBUG
        if FileManager.default.fileExists(
            atPath: container.appendingPathComponent(".ui-testing-workspace").path
        ) {
            return container.appendingPathComponent("ui-testing", isDirectory: true)
        }
        #endif
        return container.appendingPathComponent("workspace-data", isDirectory: true)
    }

    static func prepareForApplication(isUITesting: Bool) throws -> URL {
        let container = try containerURL()
        #if DEBUG
        let testingMarker = container.appendingPathComponent(".ui-testing-workspace")
        if isUITesting {
            let directory = container.appendingPathComponent("ui-testing", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data().write(to: testingMarker, options: .atomic)
            return directory
        }
        if FileManager.default.fileExists(atPath: testingMarker.path) {
            try FileManager.default.removeItem(at: testingMarker)
        }
        #endif

        let directory = container.appendingPathComponent("workspace-data", isDirectory: true)
        let legacyDirectory = URL.applicationSupportDirectory
            .appendingPathComponent("plastickarma.otodo", isDirectory: true)
        try WorkspaceStorageMigration.prepare(
            legacyURL: legacyDirectory,
            destinationURL: directory
        )
        return directory
    }
}
