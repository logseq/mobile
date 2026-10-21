import Foundation
import LogseqCoreABI

enum LogseqCorePriority: Int, Sendable {
    case maintenance
    case normal
    case interaction
}

final class LogseqCoreExecutor: @unchecked Sendable {
    static let shared = LogseqCoreExecutor()

    private struct Job: @unchecked Sendable {
        let callCore: @Sendable (String) -> String
        let requestJSON: String
        let priority: LogseqCorePriority
        let complete: @Sendable (String) -> Void
    }

    private final class SynchronousResult: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var value = ""

        func finish(with value: String) {
            lock.lock()
            self.value = value
            lock.unlock()
            semaphore.signal()
        }

        func wait() -> String {
            semaphore.wait()
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class State: @unchecked Sendable {
        private let condition = NSCondition()
        private var jobs: [Job] = []

        func enqueue(_ job: Job) {
            condition.lock()
            jobs.append(job)
            condition.signal()
            condition.unlock()
        }

        func next() -> Job {
            condition.lock()
            while jobs.isEmpty {
                condition.wait()
            }
            var selectedIndex = jobs.startIndex
            for index in jobs.indices where jobs[index].priority.rawValue > jobs[selectedIndex].priority.rawValue {
                selectedIndex = index
            }
            let job = jobs.remove(at: selectedIndex)
            condition.unlock()
            return job
        }
    }

    private let state: State
    private let thread: Thread

    private init() {
        let state = State()
        self.state = state
        self.thread = Thread {
            Thread.current.name = "LogseqCore"
            #if LOGSEQ_CORE
            LogseqCoreABI.logseq_initialize()
            #endif
            while true {
                let job = state.next()
                #if canImport(ObjectiveC)
                let response = autoreleasepool { job.callCore(job.requestJSON) }
                #else
                let response = job.callCore(job.requestJSON)
                #endif
                job.complete(response)
            }
        }
        thread.name = "LogseqCore"
        thread.start()
    }

    func call(
        _ callCore: @escaping @Sendable (String) -> String,
        requestJSON: String,
        priority: LogseqCorePriority = .normal
    ) async -> String {
        await withCheckedContinuation { continuation in
            state.enqueue(Job(
                callCore: callCore,
                requestJSON: requestJSON,
                priority: priority,
                complete: { continuation.resume(returning: $0) }
            ))
        }
    }

    func callSync(
        _ callCore: @escaping @Sendable (String) -> String,
        requestJSON: String,
        priority: LogseqCorePriority = .interaction
    ) -> String {
        if Thread.current === thread {
            return callCore(requestJSON)
        }

        let result = SynchronousResult()
        state.enqueue(Job(
            callCore: callCore,
            requestJSON: requestJSON,
            priority: priority,
            complete: { result.finish(with: $0) }
        ))
        return result.wait()
    }
}
