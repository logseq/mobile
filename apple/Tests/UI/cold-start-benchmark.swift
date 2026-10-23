import SwiftUI
import UIKit
import QuartzCore
import Darwin
import os
import LogseqModel
import Logseq

// Shared first-frame probe. The default entry below measures only the local
// renderer; the application-entry driver also runs the real app lifecycle.
@MainActor private enum Clock {
    static let appInit = CACurrentMediaTime()
    static let measuresCPU = ProcessInfo.processInfo.environment["LOGSEQ_BENCH_CPU"] == "1"
    private static let log = OSLog(subsystem: "com.logseq.benchmark", category: .pointsOfInterest)
    static func begin(_ name: StaticString) { os_signpost(.begin, log: log, name: name) }
    static func end(_ name: StaticString) { os_signpost(.end, log: log, name: name) }
    static let processBirth: CFTimeInterval = {
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        precondition(sysctl(&mib, u_int(mib.count), &process, &size, nil, 0) == 0)
        let birth = Double(process.kp_proc.p_starttime.tv_sec)
            + Double(process.kp_proc.p_starttime.tv_usec) / 1_000_000
        return CACurrentMediaTime() - (Date().timeIntervalSince1970 - birth)
    }()
    static func milliseconds(at time: CFTimeInterval = CACurrentMediaTime()) -> Double {
        (time - processBirth) * 1_000
    }
    static func cpuMilliseconds(_ clock: clockid_t) -> Double {
        var time = timespec()
        precondition(clock_gettime(clock, &time) == 0)
        return Double(time.tv_sec) * 1_000 + Double(time.tv_nsec) / 1_000_000
    }
    static func mark(_ stage: String) {
        let start = appInit
        let cpu = measuresCPU
            ? " process_cpu_ms=\(cpuMilliseconds(CLOCK_PROCESS_CPUTIME_ID)) main_cpu_ms=\(cpuMilliseconds(CLOCK_THREAD_CPUTIME_ID))" : ""
        print("COLD_START stage=\(stage) process_ms=\(milliseconds()) app_ms=\((CACurrentMediaTime() - start) * 1_000)\(cpu)")
    }
}

@MainActor private final class FrameProbe: NSObject {
    static let shared = FrameProbe()
    private var updates: AnyObject?
    private var display: CADisplayLink?
    private var presentationTime: CFTimeInterval?
    private var committedRows = 0
    private var firstCommitTime: CFTimeInterval?

    func start(in window: UIWindow) {
        guard #available(iOS 18.0, *), let scene = window.windowScene else {
            fatalError("Precise startup measurement requires iOS 18 or later")
        }
        let link = UIUpdateLink(windowScene: scene)
        link.addAction(to: .afterCATransactionCommit) { [weak self] link, info in
            guard let self else { return }
            let committedAt = CACurrentMediaTime()
            func countVisibleTitles(_ view: UIView) -> Int {
                guard !view.isHidden, view.alpha > 0.01 else { return 0 }
                let own: Int
                if let label = view as? UILabel,
                   NSStringFromClass(type(of: label)).contains("OutlinerTitleLabel"),
                   !(label.attributedText?.string ?? label.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !label.convert(label.bounds, to: window).intersection(window.bounds).isEmpty {
                    own = 1
                } else { own = 0 }
                return own + view.subviews.reduce(0) { $0 + countVisibleTitles($1) }
            }
            func hasOpaqueLaunchCover(_ view: UIView) -> Bool {
                guard !view.isHidden, view.alpha > 0.01 else { return false }
                if view.accessibilityIdentifier == "launch.transition",
                   (view.backgroundColor?.cgColor.alpha ?? 0) > 0.01 {
                    return true
                }
                return view.subviews.contains(where: hasOpaqueLaunchCover)
            }
            let rows = countVisibleTitles(window)
            guard rows > 0, !hasOpaqueLaunchCover(window) else { return }
            firstCommitTime = committedAt
            link.isEnabled = false
            Clock.end("FirstLayout")
            committedRows = rows
            presentationTime = max(committedAt, info.estimatedPresentationTime)
            Clock.mark("first_commit")
            #if !LOGSEQ_BENCH_EXTERNAL_ENTRY
            Task { await LogseqLogseqRuntime.shared.store.completeLaunchPresentation() }
            #endif
            print("COLD_START estimated_presentation_ms=\(Clock.milliseconds(at: info.estimatedPresentationTime)) nonempty_rows=\(committedRows)")
        }
        updates = link
        link.isEnabled = true
        let display = CADisplayLink(target: self, selector: #selector(tick))
        display.add(to: .main, forMode: .common)
        self.display = display
    }

    @objc private func tick() {
        guard let presentationTime, let firstCommitTime, let display,
              display.timestamp >= presentationTime else { return }
        display.invalidate()
        Clock.mark("first_display_after_commit")
        let cpu = Clock.measuresCPU
            ? ",\"process_cpu_ms\":\(Clock.cpuMilliseconds(CLOCK_PROCESS_CPUTIME_ID)),\"main_cpu_ms\":\(Clock.cpuMilliseconds(CLOCK_THREAD_CPUTIME_ID))" : ""
        print("COLD_START_RESULT {\"process_ms\":\(Clock.milliseconds()),\"first_commit_ms\":\(Clock.milliseconds(at: firstCommitTime)),\"nonempty_rows\":\(committedRows)\(cpu)}")
        #if LOGSEQ_BENCH_APP_ENTRY
        print("COLD_START_AUTH state=\(LogseqLogseqRuntime.shared.authentication.state.rawValue)")
        #endif
        print("RUNTIME_CHECK_COMPLETE")
        exit(0)
    }
}

#if !LOGSEQ_BENCH_EXTERNAL_ENTRY
struct ColdStartBenchmark: App {
    init() {
        setbuf(stdout, nil)
        _ = Clock.processBirth
        Clock.mark("app_init")
        guard let graphID = ProcessInfo.processInfo.environment["LOGSEQ_BENCH_GRAPH_ID"], !graphID.isEmpty else {
            fatalError("Set LOGSEQ_BENCH_GRAPH_ID to a graph in the isolated fixture")
        }
        UserDefaults.standard.set(graphID, forKey: "logseq.selectedGraphId")
        let runtime = LogseqLogseqRuntime.shared
        Clock.mark("runtime_initialized")
        runtime.startLocalLaunchLoad()
        Clock.mark("local_graph_loaded")
        runtime.startLGRenderer()
        try! runtime.lgRuntime.applyHostUpdate(kind: "authentication", payload: #"{"state":"signedIn"}"#)
        Clock.mark("renderer_started")
        Clock.begin("ViewCreation")
    }
    var body: some Scene {
        WindowGroup {
            LGRendererRoot(renderer: LogseqLogseqRuntime.shared.lgRuntime.renderer).onAppear {
                Clock.end("ViewCreation")
                Clock.begin("FirstLayout")
                Clock.mark("root_appeared")
                let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).first { $0.isKeyWindow }!
                FrameProbe.shared.start(in: window)
            }
        }
    }
}

@main @MainActor enum BenchmarkMain {
    static func main() {
        setbuf(stdout, nil)
        _ = Clock.processBirth
        Clock.mark("main_entry")
        ColdStartBenchmark.main()
    }
}
#endif
