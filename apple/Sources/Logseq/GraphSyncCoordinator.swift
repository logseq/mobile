import Foundation
import os

actor GraphSyncCoordinator {
    typealias ForegroundOperation = @MainActor @Sendable (String) async -> Void
    typealias BackgroundOperation = @MainActor @Sendable () async -> Bool
    typealias BackgroundExpirationCleanup = @MainActor @Sendable () async -> Void

    // A caller keeps its expiration result even after the shared run finishes.
    // Repeated cancellation/OS expiration must await the same cleanup and may
    // never look up a later run by a global "current background" slot.
    final class BackgroundRequest: Sendable {
        fileprivate struct State: Sendable {
            var expired = false
            var expiration: Task<Task<Bool, Never>?, Never>?
        }
        fileprivate let id = UUID()
        fileprivate let state = OSAllocatedUnfairLock(initialState: State())
    }

    private var foregroundTask: Task<Void, Never>?
    private var backgroundTask: Task<Bool, Never>?
    private var backgroundGeneration = UUID()
    private var backgroundCallers: Set<UUID> = []
    private var backgroundExpirationCleanup: BackgroundExpirationCleanup?
    private var networkAvailable = true
    private var desiredForeground: (graphID: String, operation: ForegroundOperation)?

    func startForeground(
        graphID: String,
        operation: @escaping ForegroundOperation
    ) async {
        desiredForeground = (graphID, operation)
        guard networkAvailable else {
            await cancelForegroundTask()
            return
        }
        await launchForeground(graphID: graphID, operation: operation)
    }

    func setNetworkAvailable(_ available: Bool) async {
        guard networkAvailable != available else { return }
        networkAvailable = available
        if !available {
            await cancelForegroundTask()
        } else if let desiredForeground {
            await launchForeground(
                graphID: desiredForeground.graphID,
                operation: desiredForeground.operation
            )
        }
    }

    private func launchForeground(
        graphID: String,
        operation: @escaping ForegroundOperation
    ) async {
        let previousForeground = foregroundTask
        let activeBackground = backgroundTask
        previousForeground?.cancel()
        foregroundTask = Task {
            if let activeBackground {
                _ = await activeBackground.value
            }
            if let previousForeground {
                await previousForeground.value
            }
            guard !Task.isCancelled else { return }
            await operation(graphID)
        }
    }

    func stopForeground() async {
        desiredForeground = nil
        await cancelForegroundTask()
    }

    func kickForeground() async {
        guard networkAvailable, let desiredForeground else { return }
        await launchForeground(
            graphID: desiredForeground.graphID,
            operation: desiredForeground.operation
        )
    }

    private func cancelForegroundTask() async {
        guard let foregroundTask else { return }
        self.foregroundTask = nil
        foregroundTask.cancel()
        await foregroundTask.value
    }

    func runBackground(
        request: BackgroundRequest = BackgroundRequest(),
        expirationCleanup: @escaping BackgroundExpirationCleanup = {},
        operation: @escaping BackgroundOperation
    ) async -> Bool {
        guard !Task.isCancelled, !request.state.withLock({ $0.expired }) else { return false }
        if backgroundTask == nil {
            let previousForeground = foregroundTask
            foregroundTask = nil
            previousForeground?.cancel()
            backgroundGeneration = UUID()
            backgroundExpirationCleanup = expirationCleanup
            backgroundTask = Task {
                if let previousForeground {
                    await previousForeground.value
                }
                guard !Task.isCancelled else { return false }
                return await operation()
            }
        }
        let generation = backgroundGeneration
        let task = backgroundTask!
        backgroundCallers.insert(request.id)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { _ = await self.expireBackground(request: request) }
        }
        if backgroundGeneration == generation {
            backgroundTask = nil
            backgroundCallers.removeAll()
            backgroundExpirationCleanup = nil
        }
        return result && !Task.isCancelled && !request.state.withLock { $0.expired }
    }

    // Expiring one coalesced waiter releases only that waiter's budget. The
    // final waiter cancels the captured run, drains its reminder writes, and
    // returns that exact network task for teardown after OS completion.
    func expireBackground(request: BackgroundRequest) async -> Task<Bool, Never>? {
        if let expiration = request.state.withLock({ $0.expiration }) {
            return await expiration.value
        }
        let isLastCaller = backgroundCallers.remove(request.id) != nil && backgroundCallers.isEmpty
        let task = isLastCaller ? backgroundTask : nil
        let cleanup = isLastCaller ? backgroundExpirationCleanup : nil
        task?.cancel()
        let expiration = Task {
            await cleanup?()
            return task
        }
        request.state.withLock {
            $0.expired = true
            $0.expiration = expiration
        }
        return await expiration.value
    }

    func cancelBackground() async {
        guard let backgroundTask else { return }
        self.backgroundTask = nil
        backgroundGeneration = UUID()
        backgroundCallers.removeAll()
        backgroundExpirationCleanup = nil
        backgroundTask.cancel()
        _ = await backgroundTask.value
    }
}
