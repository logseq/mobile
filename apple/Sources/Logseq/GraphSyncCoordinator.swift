import Foundation
import os

actor GraphSyncCoordinator {
    typealias ForegroundOperation = @MainActor @Sendable (String) async -> Void
    typealias BackgroundOperation = @MainActor @Sendable () async -> Bool
    typealias BackgroundExpirationCleanup = @MainActor @Sendable () async -> Void

    fileprivate final class BackgroundRun: Sendable {
        struct State: Sendable {
            var callers: Set<UUID> = []
            var expiration: Task<Task<Bool, Never>?, Never>?
        }
        let task: Task<Bool, Never>
        let cleanup: BackgroundExpirationCleanup
        let state = OSAllocatedUnfairLock(initialState: State())

        init(task: Task<Bool, Never>, cleanup: @escaping BackgroundExpirationCleanup) {
            self.task = task
            self.cleanup = cleanup
        }
    }

    // A caller keeps its expiration result even after the shared run finishes.
    // Repeated cancellation/OS expiration must await the same cleanup and may
    // never look up a later run by a global "current background" slot.
    final class BackgroundRequest: Sendable {
        fileprivate struct State: Sendable {
            var expired = false
            var expiration: Task<Task<Bool, Never>?, Never>?
            var run: BackgroundRun?
        }
        fileprivate let id = UUID()
        fileprivate let state = OSAllocatedUnfairLock(initialState: State())
    }

    private var foregroundTask: Task<Void, Never>?
    private var backgroundRun: BackgroundRun?
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
        let activeBackground = backgroundRun?.task
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
        if backgroundRun == nil {
            let previousForeground = foregroundTask
            foregroundTask = nil
            previousForeground?.cancel()
            let task = Task {
                if let previousForeground {
                    await previousForeground.value
                }
                guard !Task.isCancelled else { return false }
                return await operation()
            }
            backgroundRun = BackgroundRun(task: task, cleanup: expirationCleanup)
        }
        let run = backgroundRun!
        request.state.withLock { $0.run = run }
        _ = run.state.withLock { $0.callers.insert(request.id) }
        let result = await withTaskCancellationHandler {
            await run.task.value
        } onCancel: {
            request.state.withLock { $0.expired = true }
            Task { _ = await self.expireBackground(request: request) }
        }
        if Task.isCancelled || request.state.withLock({ $0.expired }) {
            _ = await expireBackground(request: request)
        } else {
            _ = run.state.withLock { $0.callers.remove(request.id) }
        }
        if backgroundRun === run { backgroundRun = nil }
        return result && !Task.isCancelled && !request.state.withLock { $0.expired }
    }

    // Expiring one coalesced waiter releases only that waiter's budget. The
    // final waiter cancels the captured run, drains its reminder writes, and
    // returns that exact network task for teardown after OS completion.
    func expireBackground(request: BackgroundRequest) async -> Task<Bool, Never>? {
        if let expiration = request.state.withLock({ $0.expiration }) {
            return await expiration.value
        }
        // The request retains its exact run after normal completion. An OS
        // expiration may already have claimed the budget while its actor call
        // is queued; it must still drain that run, never a newer global slot.
        let expiration = request.state.withLock { $0.run }.map { run in
            run.state.withLock { state -> Task<Task<Bool, Never>?, Never> in
                state.callers.remove(request.id)
                guard state.callers.isEmpty else { return Task { nil } }
                if let expiration = state.expiration { return expiration }
                run.task.cancel()
                let task = run.task
                let cleanup = run.cleanup
                let expiration = Task<Task<Bool, Never>?, Never> {
                    await cleanup()
                    return task
                }
                state.expiration = expiration
                return expiration
            }
        } ?? Task { nil }
        request.state.withLock {
            $0.expired = true
            $0.expiration = expiration
        }
        return await expiration.value
    }

    func cancelBackground() async {
        guard let run = backgroundRun else { return }
        backgroundRun = nil
        run.task.cancel()
        _ = await run.task.value
    }
}
