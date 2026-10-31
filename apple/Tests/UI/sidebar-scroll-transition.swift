import UIKit
import SwiftUI
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class SidebarScrollSampler: NSObject {
    let scroll: UIScrollView
    let baseline: CGPoint
    let viewportHeight: CGFloat
    private var displayLink: CADisplayLink?
    private(set) var maximumModelShift: CGFloat = 0
    private(set) var maximumDisplayedShift: CGFloat = 0
    private(set) var frames = 0
    private(set) var maximumViewportShift: CGFloat = 0

    init(scroll: UIScrollView) {
        self.scroll = scroll
        baseline = scroll.contentOffset
        viewportHeight = scroll.bounds.height
        super.init()
        displayLink = CADisplayLink(target: self, selector: #selector(sample))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func sample() {
        frames += 1
        let displayed = scroll.layer.presentation()?.bounds.origin ?? scroll.bounds.origin
        maximumModelShift = max(maximumModelShift, abs(scroll.contentOffset.y - baseline.y))
        maximumDisplayedShift = max(maximumDisplayedShift, abs(displayed.y - baseline.y))
        maximumViewportShift = max(maximumViewportShift, abs(scroll.bounds.height - viewportHeight))
    }

    func stop() { displayLink?.invalidate(); displayLink = nil }
}

@main struct SidebarScrollTransitionCheck {
    @MainActor static func main() async throws {
        let pages: [[String: Any]] = (0..<40).map { ["uuid": "favorite-\($0)", "title": "Favorite page \($0)"] }
        let recent: [[String: Any]] = (0..<40).map { ["uuid": "recent-\($0)", "title": "Recent page \($0)"] }
        let result: [String: Any] = ["graphName": "Sidebar regression", "selectedGraphId": "sidebar",
            "favorites": pages, "recentPages": recent]
        let snapshot = String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { _ in snapshot }))
        try runtime.applyCoreResponse(snapshot)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        try await Task.sleep(for: .milliseconds(350))
        guard let drawer = backend.rootIDs.flatMap(descendants).first(where: { backend.model(id: $0)?.kind == .drawer }) else {
            throw failure("Missing drawer")
        }
        try backend.performPress(node: find("button.sidebar")!)
        try await Task.sleep(for: .milliseconds(500))
        guard let scroll = views(window).compactMap({ $0 as? UIScrollView }).first(where: {
            $0.contentSize.height > 3000 && $0.bounds.width < window.bounds.width * 0.85
        }) else { throw failure("Missing Recent/Favorites scroller") }
        print("SIDEBAR_SCROLL type=\(type(of: scroll)) size=\(scroll.contentSize) frame=\(scroll.frame) inset=\(scroll.adjustedContentInset)")
        let bottom = scroll.contentSize.height - scroll.bounds.height
        for offset: CGFloat in [0, 400, 2200, bottom] {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            try await Task.sleep(for: .milliseconds(200))
            guard abs(scroll.contentOffset.y - offset) < 1 else {
                throw failure("The fixture must reach the requested scroll position before toggling")
            }
            let sampler = SidebarScrollSampler(scroll: scroll)
            for selected in [false, true, false, true] {
                try backend.performToggle(node: drawer, checked: selected)
                try await Task.sleep(for: .milliseconds(420))
            }
            sampler.stop()
            print("SIDEBAR offset=\(offset) frames=\(sampler.frames) modelShift=\(sampler.maximumModelShift) displayedShift=\(sampler.maximumDisplayedShift) viewportShift=\(sampler.maximumViewportShift)")
            guard sampler.maximumModelShift < 1, sampler.maximumDisplayedShift < 1, sampler.maximumViewportShift < 1 else {
                throw failure("Drawer transforms must preserve the Recent/Favorites scroll viewport; offset=\(offset), displayed shift=\(sampler.maximumDisplayedShift), viewport shift=\(sampler.maximumViewportShift)")
            }
            guard scroll.isScrollEnabled, scroll.window === window else {
                throw failure("The retained sidebar must resume scrolling after transitions")
            }
        }
        guard runtime.lastError == nil else { throw failure(runtime.lastError!) }
        print("PASS: Recent/Favorites retain their displayed scroll position while toggling the sidebar")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SidebarScrollTransition", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
