import Foundation
import Network

final class ConnectivityMonitor: @unchecked Sendable {
    let connectivityChanges: AsyncStream<Bool>

    var currentConnectivity: Bool {
        state.currentConnectivity
    }

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let state: State

    init(
        monitor: NWPathMonitor = NWPathMonitor(),
        queue: DispatchQueue = DispatchQueue(label: "plastickarma.otodo.connectivity")
    ) {
        self.monitor = monitor
        self.queue = queue

        let state = State(initialConnectivity: monitor.currentPath.status == .satisfied)
        self.state = state
        connectivityChanges = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            state.install(continuation)
        }

        monitor.pathUpdateHandler = { [state] path in
            state.update(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        state.finish()
    }

    func cancel() {
        monitor.cancel()
        state.finish()
    }
}

private extension ConnectivityMonitor {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var connectivity: Bool
        private var lastEmittedConnectivity: Bool?
        private var continuation: AsyncStream<Bool>.Continuation?
        private var isFinished = false

        init(initialConnectivity: Bool) {
            connectivity = initialConnectivity
        }

        var currentConnectivity: Bool {
            lock.withLock { connectivity }
        }

        func install(_ continuation: AsyncStream<Bool>.Continuation) {
            let initialConnectivity: Bool? = lock.withLock {
                guard !isFinished else {
                    return nil
                }
                self.continuation = continuation
                lastEmittedConnectivity = connectivity
                return connectivity
            }

            guard let initialConnectivity else {
                continuation.finish()
                return
            }
            continuation.yield(initialConnectivity)
        }
        func update(_ connectivity: Bool) {
            let update: (AsyncStream<Bool>.Continuation, Bool)? = lock.withLock {
                guard !isFinished else {
                    return nil
                }
                self.connectivity = connectivity
                guard lastEmittedConnectivity != connectivity,
                      let continuation
                else {
                    return nil
                }
                lastEmittedConnectivity = connectivity
                return (continuation, connectivity)
            }
            if let update {
                update.0.yield(update.1)
            }
        }

        func finish() {
            let continuation: AsyncStream<Bool>.Continuation? = lock.withLock {
                guard !isFinished else {
                    return nil
                }
                isFinished = true
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.finish()
        }
    }
}
