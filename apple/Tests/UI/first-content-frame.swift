import UIKit
import QuartzCore
@testable import Logseq

@MainActor private final class ReadinessDisplayClock: NSObject {
    private(set) var link: CADisplayLink!
    override init() {
        super.init()
        link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
    }
    @objc private func tick() { }
}

@main struct FirstContentFrameCheck {
    @MainActor static func main() async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "FirstContentFrame", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }!
        let observer = LogseqFirstContentFrame()
        var callbacks = 0
        observer.observe(in: window) { callbacks += 1 }
        try require(callbacks == 0, "First-frame work must not run synchronously during view construction")
        window.rootViewController?.view.setNeedsLayout()
        for _ in 0..<100 where callbacks == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(callbacks == 1, "The first committed content frame must release deferred work")
        observer.observe(in: window) { callbacks += 1 }
        window.rootViewController?.view.setNeedsLayout()
        try await Task.sleep(for: .milliseconds(50))
        try require(callbacks == 1, "A later appearance must not replay first-frame work")
        let transition = LogseqLaunchTransition.shared
        transition.show(in: window)
        guard let cover = window.subviews.first(where: { $0.accessibilityIdentifier == "launch.transition" }) else {
            throw NSError(domain: "FirstContentFrame", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The launch-cover fixture did not mount"])
        }
        let displayClock = ReadinessDisplayClock()
        defer { displayClock.link.invalidate() }
        var targetPresentation: CFTimeInterval?
        var update: AnyObject?
        if #available(iOS 18.0, *), let scene = window.windowScene {
            let link = UIUpdateLink(windowScene: scene)
            link.addAction(to: .afterCATransactionCommit) { _, info in
                if targetPresentation == nil, (cover.backgroundColor?.cgColor.alpha ?? 0) == 0 {
                    targetPresentation = max(CACurrentMediaTime(), info.estimatedPresentationTime)
                }
            }
            link.isEnabled = true
            update = link
        }
        defer {
            if #available(iOS 18.0, *), let link = update as? UIUpdateLink { link.isEnabled = false }
        }
        let coveredObserver = LogseqFirstContentFrame()
        var coveredCallbacks = 0
        var callbackDisplayTimestamp: CFTimeInterval?
        coveredObserver.observe(in: window) {
            coveredCallbacks += 1
            callbackDisplayTimestamp = displayClock.link.timestamp
        }
        window.rootViewController?.view.setNeedsLayout()
        try await Task.sleep(for: .milliseconds(100))
        try require(cover.backgroundColor?.cgColor.alpha == 1,
                    "The covered-frame fixture must remain opaque")
        try require(coveredCallbacks == 0,
                    "A commit behind the opaque launch cover must not release sidebar work")
        transition.finish(reduceMotion: false)
        for _ in 0..<100 where coveredCallbacks == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(coveredCallbacks == 1,
                    "The displayed uncovered frame must release deferred work")
        if #available(iOS 18.0, *) {
            try require(targetPresentation != nil && callbackDisplayTimestamp != nil,
                        "The uncovered frame must supply presentation timestamps")
            try require(callbackDisplayTimestamp! >= targetPresentation!,
                        "Sidebar work must wait until a display tick reaches the uncovered frame's presentation time")
        }
        try require(cover.superview != nil,
                    "The independent logo fade must not delay content readiness")
        coveredObserver.observe(in: window) { coveredCallbacks += 1 }
        try await Task.sleep(for: .milliseconds(50))
        try require(coveredCallbacks == 1, "Uncovering content must release work exactly once")
        print("PASS: native frame observation waits for uncovered content and releases work exactly once")
    }
}
