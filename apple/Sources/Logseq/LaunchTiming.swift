import Darwin
import Foundation
import QuartzCore
import os

/// Reads the current process birth time so launch measurements include pre-main work.
enum LogseqLaunchTiming {
    private static let detailed = ProcessInfo.processInfo.environment["LOGSEQ_TRACE_STARTUP"] == "1"
    private static let log = OSLog(subsystem: "com.logseq.logseq", category: .pointsOfInterest)
    @MainActor private static var finished = false

    @MainActor static func measure<T>(_ name: StaticString, _ operation: () throws -> T) rethrows -> T {
        guard detailed, !finished else { return try operation() }
        let started = CACurrentMediaTime()
        os_signpost(.begin, log: log, name: name)
        defer {
            let elapsed = (CACurrentMediaTime() - started) * 1_000
            os_signpost(.end, log: log, name: name)
            print(String(format: "LOGSEQ_LAUNCH_STEP name=%@ elapsed_ms=%.3f", String(describing: name), elapsed))
        }
        return try operation()
    }

    @MainActor static func finish() { finished = true }

    static let processStartedAt: TimeInterval? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var selectors: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&selectors, UInt32(selectors.count), &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
    }()

    static func elapsedMilliseconds() -> Double? {
        processStartedAt.map { (Date().timeIntervalSince1970 - $0) * 1_000 }
    }
}
