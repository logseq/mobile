import SwiftUI
import UIKit
@testable import Logseq
@testable import LUIAppleBackend

@MainActor private final class ScrollTopEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        .init(succeeded: true, message: "", output: .discard)
    }
}

@MainActor private final class OriginalScrollDelegate: NSObject, UIScrollViewDelegate {
    var allowReturn = true
    var scrollEvents = 0
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool { allowReturn }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { scrollEvents += 1 }
}

@main struct JournalScrollToTopCheck {
    @MainActor static func main() async throws {
        try delegateContract()
        let rows = (0..<2000).map { index -> [String: Any] in
            ["depth": 0, "block": ["uuid": "row-\(index)", "title": "Journal block \(index)", "pageId": "journal"]]
        }
        let response = String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": [
            "selectedGraphId": "scroll-top", "graphName": "Journals", "outlinerRows": rows
        ]]), as: UTF8.self)
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: ScrollTopEffects())
        try runtime.applyCoreResponse(response)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        let original = backend.onEvent
        var topRequested = false
        backend.onEvent = { event in
            if case let .visibleRange(_, first, _) = event, first == 0 { topRequested = true }
            original?(event)
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true; window.rootViewController = nil }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func wait(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure(message)
        }
        try await wait("The journal scroller must mount") {
            views(window).compactMap { $0 as? UIScrollView }.contains { $0.contentSize.height > 10_000 }
        }
        let scroll = views(window).compactMap { $0 as? UIScrollView }.max { $0.contentSize.height < $1.contentSize.height }!
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height * 0.8), animated: false)
        try await Task.sleep(for: .milliseconds(600))
        topRequested = false
        let before = scroll.contentOffset.y
        let nativeAnimation = scroll.delegate?.scrollViewShouldScrollToTop?(scroll)
        guard nativeAnimation == false, topRequested else {
            throw failure("A distant status-bar tap must prepare the top window before moving instead of animating through unloaded rows")
        }
        guard scroll.contentOffset.y == before else { throw failure("The visible window must stay intact until the top window is ready") }
        try await wait("Status-bar return must finish at the top") { scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1 }
        try await wait("The top block must actually be visible") {
            views(window).compactMap { $0 as? UILabel }.contains { label in
                label.text == "Journal block 0" && label.convert(label.bounds, to: window).intersects(window.bounds)
            }
        }
        scroll.setContentOffset(CGPoint(x: 0, y: 50), animated: false)
        topRequested = false
        guard scroll.delegate?.scrollViewShouldScrollToTop?(scroll) != false, !topRequested else {
            throw failure("Nearby status-bar returns must retain the standard iOS animation")
        }
        print("PASS: distant status-bar returns prepare the top window and nearby returns keep native animation")
    }

    @MainActor private static func delegateContract() throws {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scroll.contentSize = CGSize(width: 320, height: 10_000)
        let original = OriginalScrollDelegate()
        scroll.delegate = original
        let probe = LUIVirtualScrollTopBridge.Probe()
        scroll.addSubview(probe)
        probe.install()
        defer { probe.uninstall() }
        let count = original.scrollEvents
        scroll.delegate?.scrollViewDidScroll?(scroll)
        guard original.scrollEvents == count + 1 else { throw failure("The original SwiftUI delegate must keep receiving scroll events") }
        var requests = 0
        probe.requestTop = { requests += 1 }
        scroll.setContentOffset(CGPoint(x: 0, y: 5000), animated: false)
        original.allowReturn = false
        guard scroll.delegate?.scrollViewShouldScrollToTop?(scroll) == false, requests == 0 else {
            throw failure("The original delegate must retain its right to reject a return")
        }
        original.allowReturn = true
        guard scroll.delegate?.scrollViewShouldScrollToTop?(scroll) == false, requests == 1 else {
            throw failure("A distant return must request the top window exactly once")
        }
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        probe.prepared = true
        probe.completeReturn()
        guard scroll.contentOffset.y == 5000 else { throw failure("A new drag must cancel a pending status-bar return") }
        probe.uninstall()
        guard scroll.delegate === original else { throw failure("Unmounting must restore the original delegate") }
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "JournalScrollToTop", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
