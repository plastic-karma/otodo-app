import Observation
import Foundation
import OTodoCore
import WatchConnectivity
import WatchKit
import WidgetKit

// WCSession delivers on a background queue. Keep a receipt counted until its
// MainActor work has durably saved it, even if hasContentPending becomes false.
private final class PendingWatchReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func begin() { lock.withLock { count += 1 } }
    func end() { lock.withLock { count -= 1 } }
    var isEmpty: Bool { lock.withLock { count == 0 } }
}

@MainActor
@Observable
final class WatchSnapshotReceiver: NSObject, WCSessionDelegate {
    static let shared = WatchSnapshotReceiver()

    private(set) var workspace: WatchWorkspaceSnapshot?
    private(set) var errorMessage: String?
    private(set) var isReachable = false
    private(set) var isRequesting = false

    @ObservationIgnored private var started = false
    @ObservationIgnored private var wantsRefresh = false
    @ObservationIgnored private var pendingObservation: NSKeyValueObservation?
    @ObservationIgnored private var backgroundTasks: [UUID: WKWatchConnectivityRefreshBackgroundTask] = [:]
    nonisolated private let pendingReceipts = PendingWatchReceipts()

    func start() {
        guard !started else { return }
        started = true
        WatchSmokeProgress.record("starting")
        do {
            workspace = try WatchSnapshotStorage.load()
            WatchSmokeProgress.record("cache-read", values: ["cache": workspace == nil ? "absent" : "loaded"])
        } catch {
            errorMessage = "Could not read saved todos. Refresh from your iPhone."
            WatchSmokeProgress.failure("Reading cached snapshot", error: error, terminal: true)
        }
        guard WCSession.isSupported() else {
            errorMessage = "Watch Connectivity is unavailable on this device."
            WatchSmokeProgress.record("unsupported", values: ["terminalError": "WatchConnectivity unsupported"])
            return
        }
        let session = WCSession.default
        session.delegate = self
        pendingObservation = session.observe(\.hasContentPending, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.completeBackgroundTasksIfReady()
            }
        }
        session.activate()
        recordReadiness("activation-requested")
    }

    func refresh() {
        start()
        wantsRefresh = true
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        recordReadiness("refresh-readiness")
        guard session.activationState == .activated else { return }
        isReachable = session.isReachable
        guard isReachable, !isRequesting else { return }
        wantsRefresh = false
        isRequesting = true
        WatchSmokeProgress.record("request-sent", values: ["request": "sent"])
        session.sendMessage([WatchSnapshotStorage.requestKey: true], replyHandler: { @Sendable [weak self] reply in
            let data = reply[WatchSnapshotStorage.contextKey] as? Data
            let malformed = WatchSmokeProgress.enabled && reply[WatchSnapshotStorage.contextKey] != nil && data == nil
            self?.enqueue(data: data, isReply: true, invalidReply: malformed)
        }, errorHandler: { @Sendable [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                isRequesting = false
                isReachable = WCSession.default.isReachable
                errorMessage = "Could not refresh: \(message)"
                WatchSmokeProgress.failure("Requesting snapshot", error: error)
                recordReadiness("request-failed")
                completeBackgroundTasksIfReady()
            }
        })
    }

    func retainBackgroundTask(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        let identifier = UUID()
        backgroundTasks[identifier] = task
        task.expirationHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.backgroundTasks.removeValue(forKey: identifier)?.setTaskCompletedWithSnapshot(false)
            }
        }
        start()
        completeBackgroundTasksIfReady()
    }

    private func completeBackgroundTasksIfReady() {
        guard WCSession.isSupported(), pendingReceipts.isEmpty else { return }
        let session = WCSession.default
        guard session.activationState == .activated, !session.hasContentPending else { return }
        let completed = backgroundTasks.values
        backgroundTasks.removeAll()
        for task in completed {
            task.setTaskCompletedWithSnapshot(false)
        }
    }

    private func accept(_ data: Data) {
        do {
            let incoming = try JSONDecoder().decode(WatchWorkspaceSnapshot.self, from: data)
            if let workspace, incoming.snapshot.generatedAt <= workspace.snapshot.generatedAt {
                return
            }
            try WatchSnapshotStorage.save(data: data)
            workspace = incoming
            errorMessage = nil
            WatchSmokeProgress.record("snapshot-accepted", values: ["snapshot": "persisted"])
            WidgetCenter.shared.reloadTimelines(ofKind: WatchSnapshotStorage.widgetKind)
        } catch {
            errorMessage = "Could not save the latest todos. Refresh from your iPhone."
            WatchSmokeProgress.failure("Decoding or saving received snapshot", error: error, terminal: true)
        }
    }

    nonisolated private func enqueue(
        data: Data?,
        isReply: Bool = false,
        invalidReply: Bool = false,
        error: String? = nil,
        receiptStarted: Bool = false
    ) {
        if !receiptStarted { pendingReceipts.begin() }
        Task { @MainActor [weak self, pendingReceipts] in
            defer {
                pendingReceipts.end()
                self?.completeBackgroundTasksIfReady()
            }
            guard let self else { return }
            if isReply {
                isRequesting = false
                errorMessage = nil
                WatchSmokeProgress.record("reply-received", values: ["reply": data == nil ? "deferred" : "snapshot"])
                if invalidReply {
                    WatchSmokeProgress.record("invalid-reply", values: ["terminalError": "Invalid snapshot reply payload"])
                }
            }
            if let data {
                accept(data)
            } else if let error {
                errorMessage = error
                WatchSmokeProgress.record("receipt-error", values: ["terminalError": error])
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let activated = activationState == .activated
        let reachable = session.isReachable
        let data = session.receivedApplicationContext[WatchSnapshotStorage.contextKey] as? Data
        let message = error?.localizedDescription
        if let data { enqueue(data: data) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            isReachable = reachable
            recordReadiness("activation-completed")
            if let error { WatchSmokeProgress.failure("Activating connectivity", error: error) }
            if let message { errorMessage = "Could not connect: \(message)" }
            if activated {
                if wantsRefresh { refresh() }
                completeBackgroundTasksIfReady()
            } else {
                let completed = backgroundTasks.values
                backgroundTasks.removeAll()
                for task in completed { task.setTaskCompletedWithSnapshot(false) }
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }
            isReachable = reachable
            recordReadiness("reachability-changed")
            if reachable, wantsRefresh || WKApplication.shared().applicationState == .active {
                refresh()
            }
        }
    }

    private func recordReadiness(_ event: String) {
        guard WatchSmokeProgress.enabled else { return }
        let session = WCSession.default
        WatchSmokeProgress.record(event, values: [
            "activation": String(session.activationState.rawValue),
            "installed": String(session.isCompanionAppInstalled),
            "reachable": String(session.isReachable),
            "ready": String(session.activationState == .activated),
        ])
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        enqueue(data: applicationContext[WatchSnapshotStorage.contextKey] as? Data)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        enqueue(data: userInfo[WatchSnapshotStorage.contextKey] as? Data)
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        pendingReceipts.begin()
        // The system removes this URL after the delegate method returns.
        do {
            let data = try Data(contentsOf: file.fileURL)
            enqueue(data: data, receiptStarted: true)
        } catch {
            enqueue(data: nil, error: "Could not read the incoming todos. Refresh from your iPhone.", receiptStarted: true)
        }
    }
}
