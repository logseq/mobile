import Foundation

actor GraphSyncCoordinator {
    typealias ForegroundOperation = @MainActor @Sendable (String) async -> Void
    typealias BackgroundOperation = @MainActor @Sendable () async -> Bool

    private var foregroundTask: Task<Void, Never>?
    private var backgroundTask: Task<Bool, Never>?
    private var backgroundGeneration = UUID()
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

    func runBackground(operation: @escaping BackgroundOperation) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let backgroundTask {
            return await backgroundTask.value
        }

        let previousForeground = foregroundTask
        foregroundTask = nil
        previousForeground?.cancel()
        let generation = UUID()
        backgroundGeneration = generation
        let task = Task {
            if let previousForeground {
                await previousForeground.value
            }
            guard !Task.isCancelled else { return false }
            return await operation()
        }
        backgroundTask = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if backgroundGeneration == generation {
            backgroundTask = nil
        }
        return result
    }

    func cancelBackground() async {
        guard let backgroundTask else { return }
        self.backgroundTask = nil
        backgroundGeneration = UUID()
        backgroundTask.cancel()
        _ = await backgroundTask.value
    }
}

@MainActor final class BackgroundTaskCompletion {
    private var finished = false

    func finish(success: Bool, completion: (Bool) -> Void) {
        guard !finished else { return }
        finished = true
        completion(success)
    }
}
