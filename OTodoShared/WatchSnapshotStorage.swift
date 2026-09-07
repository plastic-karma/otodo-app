import Foundation
import OTodoCore
import OSLog
import WatchConnectivity

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

/// Event-driven evidence for simulator smoke launches only; never writes task contents.
@MainActor
enum WatchSmokeProgress {
    nonisolated static let enabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-watch-smoke-diagnostics")
        #else
        false
        #endif
    }()
    private static var state: [String: String] = [:]
    private static var sequence = 0
    private static let logger = Logger(subsystem: "plastickarma.otodo", category: "WatchSmoke")

    static func record(_ event: String, values: @autoclosure () -> [String: String] = [:]) {
        guard enabled else { return }
        state.merge(values(), uniquingKeysWith: { _, new in new })
        state["event"] = event
        state["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        state["updatedAt"] = String(Date().timeIntervalSince1970)
        sequence += 1
        state[event + "At"] = state["updatedAt"]
        state["sequence"] = String(sequence)
        do {
            let directory = try WatchSnapshotStorage.directoryURL
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try JSONEncoder().encode(state).write(
                to: directory.appendingPathComponent("smoke-state.json"), options: .atomic
            )
        } catch {
            logger.error("Writing smoke progress failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func failure(_ operation: String, error: any Error, terminal: Bool? = nil) {
        guard enabled else { return }
        let error = error as NSError
        // No localized error text: it can include paths or payloads.
        let summary = "\(operation): \(error.domain)/\(error.code)"
        var values = ["error": summary]
        // Protected files can be temporarily inaccessible before first unlock.
        // Preserve the error but let the existing live deadline bound readiness.
        let inaccessible = error.domain == NSCocoaErrorDomain
            && (error.code == CocoaError.Code.fileReadNoPermission.rawValue
                || error.code == CocoaError.Code.fileWriteNoPermission.rawValue)
        if (terminal ?? isDefinitive(error)) && !inaccessible {
            values["terminalError"] = summary
        }
        record("error", values: values)
    }

    nonisolated static func isDefinitive(_ error: any Error) -> Bool {
        let error = error as NSError
        guard error.domain == WCErrorDomain else { return false }
        switch WCError.Code(rawValue: error.code) {
        case .sessionNotSupported, .sessionMissingDelegate, .invalidParameter,
             .payloadTooLarge, .payloadUnsupportedTypes, .messageReplyFailed,
             .messageReplyTimedOut, .fileAccessDenied, .insufficientSpace,
             .transferTimedOut, .watchOnlyApp:
            return true
        default:
            // First unlock, installation, activation and reachability can settle
            // after launch. Preserve their errors as evidence, not early failures.
            return false
        }
    }
}
