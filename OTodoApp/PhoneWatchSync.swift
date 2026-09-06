import Foundation
import OSLog
import OTodoCore
import WatchConnectivity

/// Keeps the foreground reply on WCSession's callback queue without moving its
/// non-Sendable reply closure (or session) across an actor boundary.
private final class WatchSnapshotReply: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func replace(with data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
    }

    func load() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

@MainActor
final class PhoneWatchSync: NSObject, WCSessionDelegate {
    private nonisolated static let maximumContextBytes = 60_000
    private nonisolated static let generationKey = "otodoSnapshotGeneratedAt"
    private static let logger = Logger(subsystem: "plastickarma.otodo", category: "WatchSync")

    private let connectivity: WCSession?
    private nonisolated let reply = WatchSnapshotReply()
    private var current: WatchWorkspaceSnapshot?
    private var payload: Data?
    private var needsPersistence = false
    private var lastSubmittedAt: Date?

    override init() {
        connectivity = WCSession.isSupported() ? .default : nil
        super.init()
        do {
            if let restored = try WatchSnapshotStorage.load() {
                current = restored
                payload = try JSONEncoder().encode(restored)
                reply.replace(with: payload)
            }
        } catch {
            recordFailure("Restoring the Watch snapshot", detail: error.localizedDescription)
        }
        connectivity?.delegate = self
        connectivity?.activate()
    }

    func synchronize(snapshot: TodayWidgetSnapshot, workspaceAvailable: Bool) {
        let tasks = workspaceAvailable ? snapshot.tasks : []
        if current?.workspaceAvailable != workspaceAvailable || current?.snapshot.tasks != tasks {
            let generatedAt = max(
                snapshot.generatedAt,
                current?.snapshot.generatedAt.addingTimeInterval(0.001) ?? snapshot.generatedAt
            )
            let next = WatchWorkspaceSnapshot(
                snapshot: TodayWidgetSnapshot(generatedAt: generatedAt, tasks: tasks),
                workspaceAvailable: workspaceAvailable
            )
            do {
                let data = try JSONEncoder().encode(next)
                current = next
                payload = data
                needsPersistence = true
                // A failed persistence attempt must not let foreground requests
                // answer with an obsolete workspace, especially after sign-out.
                reply.replace(with: nil)
            } catch {
                recordFailure("Encoding the Watch snapshot", detail: error.localizedDescription)
                return
            }
        }
        deliver()
    }

    private func persistIfNeeded() -> Bool {
        guard needsPersistence else { return true }
        guard let payload else { return false }
        do {
            try WatchSnapshotStorage.save(data: payload)
            needsPersistence = false
            reply.replace(with: payload)
            return true
        } catch {
            recordFailure("Saving the Watch snapshot", detail: error.localizedDescription)
            return false
        }
    }

    private func deliver(force: Bool = false) {
        guard persistIfNeeded(),
              let connectivity,
              connectivity.activationState == .activated,
              connectivity.isPaired,
              connectivity.isWatchAppInstalled,
              let current,
              let payload
        else { return }
        let generatedAt = current.snapshot.generatedAt
        guard force || lastSubmittedAt != generatedAt else { return }

        cancelObsoleteTransfers(on: connectivity, keeping: generatedAt)
        do {
            if payload.count <= Self.maximumContextBytes {
                try connectivity.updateApplicationContext([WatchSnapshotStorage.contextKey: payload])
                // WidgetKit does not necessarily mark a complication as enabled;
                // use the native expedited budget only when WCSession allows it.
                #if !targetEnvironment(simulator)
                if connectivity.isComplicationEnabled,
                   connectivity.remainingComplicationUserInfoTransfers > 0,
                   !connectivity.outstandingUserInfoTransfers.contains(where: {
                       ($0.userInfo[Self.generationKey] as? Double) == generatedAt.timeIntervalSinceReferenceDate
                   }) {
                    connectivity.transferCurrentComplicationUserInfo([
                        WatchSnapshotStorage.contextKey: payload,
                        Self.generationKey: generatedAt.timeIntervalSinceReferenceDate
                    ])
                }
                #endif
            } else if !connectivity.outstandingFileTransfers.contains(where: {
                ($0.file.metadata?[Self.generationKey] as? Double) == generatedAt.timeIntervalSinceReferenceDate
            }) {
                let directory = try transferDirectoryURL
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                // WCSession may read this URL later. Never rewrite a queued file.
                let fileURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
                try payload.write(to: fileURL, options: .atomic)
                connectivity.transferFile(fileURL, metadata: [
                    Self.generationKey: generatedAt.timeIntervalSinceReferenceDate
                ])
            }
            lastSubmittedAt = generatedAt
            cleanTransferFiles(on: connectivity)
        } catch {
            recordFailure("Sending the Watch snapshot", detail: error.localizedDescription)
        }
    }

    private var transferDirectoryURL: URL {
        get throws {
            try WatchSnapshotStorage.directoryURL.appendingPathComponent("transfers", isDirectory: true)
        }
    }

    private func cancelObsoleteTransfers(on session: WCSession, keeping generatedAt: Date) {
        let generation = generatedAt.timeIntervalSinceReferenceDate
        for transfer in session.outstandingFileTransfers {
            guard let value = transfer.file.metadata?[Self.generationKey] as? Double,
                  value != generation else { continue }
            transfer.cancel()
        }
        for transfer in session.outstandingUserInfoTransfers {
            guard let value = transfer.userInfo[Self.generationKey] as? Double,
                  value != generation else { continue }
            transfer.cancel()
        }
    }

    private func cleanTransferFiles(on session: WCSession) {
        do {
            let directory = try transferDirectoryURL
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            let outstanding = Set(session.outstandingFileTransfers.map { $0.file.fileURL.standardizedFileURL })
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard file.pathExtension == "json", !outstanding.contains(file.standardizedFileURL) else { continue }
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            recordFailure("Cleaning Watch transfer files", detail: error.localizedDescription)
        }
    }

    private func activationCompleted(errorDescription: String?) {
        if let errorDescription {
            recordFailure("Activating Watch connectivity", detail: errorDescription)
        }
        guard let connectivity, connectivity.activationState == .activated else { return }
        cleanTransferFiles(on: connectivity)
        deliver(force: true)
    }

    private func fileTransferCompleted(fileURL: URL, generation: Double?, errorDescription: String?) {
        if let errorDescription {
            recordFailure("Transferring the Watch snapshot file", detail: errorDescription)
            if generation == lastSubmittedAt?.timeIntervalSinceReferenceDate {
                lastSubmittedAt = nil
            }
        }
        do {
            let directory = try transferDirectoryURL.standardizedFileURL
            if fileURL.deletingLastPathComponent().standardizedFileURL == directory,
               FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            recordFailure("Removing a completed Watch transfer file", detail: error.localizedDescription)
        }
        if let connectivity { cleanTransferFiles(on: connectivity) }
    }

    private func recordFailure(_ operation: String, detail: String) {
        Self.logger.error("\(operation, privacy: .public): \(detail, privacy: .public)")
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let errorDescription = error?.localizedDescription
        Task { @MainActor [weak self] in
            self?.activationCompleted(errorDescription: errorDescription)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.lastSubmittedAt = nil
            self?.connectivity?.activate()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.deliver(force: true)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.deliver()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard message[WatchSnapshotStorage.requestKey] as? Bool == true else {
            replyHandler([:])
            return
        }
        if let data = reply.load(), data.count <= Self.maximumContextBytes {
            replyHandler([WatchSnapshotStorage.contextKey: data])
        } else {
            replyHandler([:])
            Task { @MainActor [weak self] in
                self?.deliver(force: true)
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: (any Error)?
    ) {
        let fileURL = fileTransfer.file.fileURL
        let generation = fileTransfer.file.metadata?[Self.generationKey] as? Double
        let errorDescription = error?.localizedDescription
        Task { @MainActor [weak self] in
            self?.fileTransferCompleted(
                fileURL: fileURL,
                generation: generation,
                errorDescription: errorDescription
            )
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: (any Error)?
    ) {
        guard let errorDescription = error?.localizedDescription else { return }
        Task { @MainActor [weak self] in
            self?.recordFailure("Transferring Watch complication data", detail: errorDescription)
        }
    }
}
