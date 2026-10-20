import Foundation
import Testing
@testable import Logseq

@Suite(.serialized) struct GraphSyncCoordinatorTests {
    @Test func replacingForegroundWaitsForThePreviousStreamToStop() async {
        let coordinator = GraphSyncCoordinator()
        let events = SyncEventRecorder()

        await coordinator.startForeground(graphID: "graph-1") { _ in
            await events.append("first-start")
            while !Task.isCancelled {
                await Task.yield()
            }
            await events.append("first-stop")
        }
        await waitForEvent("first-start", in: events)

        await coordinator.startForeground(graphID: "graph-2") { _ in
            await events.append("second-start")
        }
        await waitForEvent("second-start", in: events)

        #expect(await events.snapshot() == ["first-start", "first-stop", "second-start"])
    }

    @Test func backgroundCatchUpStartsOnlyAfterForegroundStops() async {
        let coordinator = GraphSyncCoordinator()
        let events = SyncEventRecorder()

        await coordinator.startForeground(graphID: "graph-1") { _ in
            await events.append("foreground-start")
            while !Task.isCancelled {
                await Task.yield()
            }
            await events.append("foreground-stop")
        }
        await waitForEvent("foreground-start", in: events)

        let succeeded = await coordinator.runBackground {
            await events.append("background-start")
            return true
        }

        #expect(succeeded)
        #expect(await events.snapshot() == ["foreground-start", "foreground-stop", "background-start"])
    }

    @Test func foregroundWaitsForActiveBackgroundCatchUp() async {
        let coordinator = GraphSyncCoordinator()
        let events = SyncEventRecorder()
        let gate = AsyncGate()

        let background = Task {
            await coordinator.runBackground {
                await events.append("background-start")
                await gate.wait()
                await events.append("background-stop")
                return true
            }
        }
        await waitForEvent("background-start", in: events)

        await coordinator.startForeground(graphID: "graph-1") { _ in
            await events.append("foreground-start")
        }
        await gate.open()
        #expect(await background.value)
        await waitForEvent("foreground-start", in: events)

        #expect(await events.snapshot() == [
            "background-start", "background-stop", "foreground-start",
        ])
    }

    @Test func concurrentBackgroundCatchUpsShareOneExecution() async {
        let coordinator = GraphSyncCoordinator()
        let probe = BackgroundExecutionProbe()

        async let first = coordinator.runBackground {
            await probe.run()
        }
        async let second = coordinator.runBackground {
            await probe.run()
        }

        let results = await [first, second]
        #expect(results == [true, true])
        #expect(await probe.counts() == BackgroundExecutionCounts(executions: 1, maximumConcurrent: 1))
    }

    @Test func explicitStopWaitsForForegroundCleanup() async {
        let coordinator = GraphSyncCoordinator()
        let events = SyncEventRecorder()

        await coordinator.startForeground(graphID: "graph-1") { _ in
            await events.append("start")
            while !Task.isCancelled {
                await Task.yield()
            }
            await events.append("cleanup")
        }
        await waitForEvent("start", in: events)

        await coordinator.stopForeground()

        #expect(await events.snapshot() == ["start", "cleanup"])
    }

    @Test func stoppingWithoutForegroundWorkIsANoOp() async {
        let coordinator = GraphSyncCoordinator()
        await coordinator.stopForeground()
    }

    @Test func foregroundCanceledWhileWaitingForBackgroundDoesNotStart() async {
        let coordinator = GraphSyncCoordinator()
        let events = SyncEventRecorder()
        let gate = AsyncGate()

        let background = Task {
            await coordinator.runBackground {
                await events.append("background-start")
                await gate.wait()
                return true
            }
        }
        await waitForEvent("background-start", in: events)

        await coordinator.startForeground(graphID: "graph-1") { _ in
            await events.append("foreground-start")
        }
        let stop = Task { await coordinator.stopForeground() }
        await gate.open()
        _ = await background.value
        await stop.value

        #expect(await events.snapshot() == ["background-start"])
    }

    @Test func cancelingBackgroundWaitsForCleanup() async {
        let coordinator = GraphSyncCoordinator()
        let events = SyncEventRecorder()

        let result = Task {
            await coordinator.runBackground {
                await events.append("start")
                while !Task.isCancelled {
                    await Task.yield()
                }
                await events.append("cleanup")
                return false
            }
        }
        await waitForEvent("start", in: events)

        await coordinator.cancelBackground()

        #expect(await result.value == false)
        #expect(await events.snapshot() == ["start", "cleanup"])
    }

    @Test func cancelingWithoutBackgroundWorkIsANoOp() async {
        let coordinator = GraphSyncCoordinator()
        await coordinator.cancelBackground()
    }

    @Test func networkLossPausesForegroundAndRecoveryRestartsIt() async {
        let coordinator = GraphSyncCoordinator()
        let events = SyncEventRecorder()

        await coordinator.startForeground(graphID: "graph-1") { _ in
            await events.append("start")
            while !Task.isCancelled {
                await Task.yield()
            }
            await events.append("stop")
        }
        await waitForEvent("start", in: events)

        await coordinator.setNetworkAvailable(false)
        await waitForEvent("stop", in: events)
        await coordinator.setNetworkAvailable(true)
        await waitForEventCount(3, in: events)

        #expect(await events.snapshot() == ["start", "stop", "start"])
        await coordinator.stopForeground()
    }

    @Test func foregroundWaitsUntilNetworkIsAvailable() async {
        let coordinator = GraphSyncCoordinator()
        let events = SyncEventRecorder()

        await coordinator.setNetworkAvailable(false)
        await coordinator.startForeground(graphID: "graph-1") { _ in
            await events.append("start")
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(await events.snapshot().isEmpty)

        await coordinator.setNetworkAvailable(true)
        await waitForEvent("start", in: events)
        #expect(await events.snapshot() == ["start"])
    }

    @Test func backgroundCanceledWhileWaitingForForegroundDoesNotStart() async {
        let coordinator = GraphSyncCoordinator()
        let events = SyncEventRecorder()
        let gate = AsyncGate()

        await coordinator.startForeground(graphID: "graph-1") { _ in
            await events.append("foreground-start")
            await gate.wait()
        }
        await waitForEvent("foreground-start", in: events)

        let background = Task {
            await coordinator.runBackground {
                await events.append("background-start")
                return true
            }
        }
        background.cancel()
        await gate.open()

        #expect(await background.value == false)
        #expect(await events.snapshot() == ["foreground-start"])
    }

    @Test @MainActor func backgroundTaskCompletionOnlyFinishesOnce() {
        let completion = BackgroundTaskCompletion()
        var results: [Bool] = []

        completion.finish(success: true) { results.append($0) }
        completion.finish(success: false) { results.append($0) }

        #expect(results == [true])
    }
}

private actor SyncEventRecorder {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private struct BackgroundExecutionCounts: Equatable {
    let executions: Int
    let maximumConcurrent: Int
}

private actor BackgroundExecutionProbe {
    private var executionCount = 0
    private var maximumConcurrentExecutions = 0
    private var concurrentExecutions = 0

    func run() async -> Bool {
        executionCount += 1
        concurrentExecutions += 1
        maximumConcurrentExecutions = max(maximumConcurrentExecutions, concurrentExecutions)
        try? await Task.sleep(for: .milliseconds(25))
        concurrentExecutions -= 1
        return true
    }

    func counts() -> BackgroundExecutionCounts {
        BackgroundExecutionCounts(
            executions: executionCount,
            maximumConcurrent: maximumConcurrentExecutions
        )
    }
}

private func waitForEvent(
    _ event: String,
    in recorder: SyncEventRecorder,
    timeout: Duration = .seconds(2)
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await recorder.snapshot().contains(event) {
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for sync event")
}

private func waitForEventCount(
    _ count: Int,
    in recorder: SyncEventRecorder,
    timeout: Duration = .seconds(2)
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await recorder.snapshot().count >= count {
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for sync event")
}
