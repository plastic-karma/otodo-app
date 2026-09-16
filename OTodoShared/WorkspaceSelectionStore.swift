import Darwin
import Foundation
import OTodoCore

actor WorkspaceSelectionStore {
    // Keep the legacy filename so existing GitHub selections restore without moving data.
    private static let fileName = "repository-selection.json"

    private let directoryURL: URL
    private let fileURL: URL

    init(
        directoryURL: URL
    ) {
        self.directoryURL = directoryURL
        fileURL = directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    func load() async throws -> WorkspaceSelection? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw OTodoError.corruptLocalState(
                message: "The saved workspace selection could not be read: \(error.localizedDescription)"
            )
        }

        do {
            return try JSONDecoder().decode(WorkspaceSelection.self, from: data)
        } catch {
            throw OTodoError.corruptLocalState(message: "The saved workspace selection is invalid")
        }
    }

    func save(_ selection: WorkspaceSelection) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(selection)
        } catch {
            throw OTodoError.corruptLocalState(
                message: "The workspace selection could not be encoded as valid local state"
            )
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            throw OTodoError.corruptLocalState(
                message: "The workspace selection directory could not be secured: \(error.localizedDescription)"
            )
        }

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(Self.fileName).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var temporaryFileExists = false
        defer {
            if temporaryFileExists {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let restrictiveAttributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: 0o600),
        ]
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: restrictiveAttributes
        ) else {
            throw OTodoError.corruptLocalState(
                message: "The workspace selection temporary file could not be created"
            )
        }
        temporaryFileExists = true

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            defer { try? handle.close() }
            try handle.synchronize()
            try fileManager.setAttributes(restrictiveAttributes, ofItemAtPath: temporaryURL.path)

            let renameResult: Int32 = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
                fileURL.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                    guard let sourcePath, let destinationPath else {
                        return Int32(-1)
                    }
                    return Darwin.rename(sourcePath, destinationPath)
                }
            }
            guard renameResult == 0 else {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            temporaryFileExists = false
            try fileManager.setAttributes(restrictiveAttributes, ofItemAtPath: fileURL.path)
        } catch {
            throw OTodoError.corruptLocalState(
                message: "The workspace selection could not be saved atomically: \(error.localizedDescription)"
            )
        }
    }

    func clear() async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw OTodoError.corruptLocalState(
                message: "The workspace selection could not be removed: \(error.localizedDescription)"
            )
        }
    }
}
