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
        let journalRows: [[String: Any]] = (0..<70).map { index in
            ["depth": 0, "block": ["uuid": "sidebar-row-\(index)", "title": "Journal row \(index)",
                                  "pageId": "today", "journalTitle": "Nov 24th, 2026", "journalDay": 20261124]]
        }
        let result: [String: Any] = ["graphName": "Sidebar regression", "selectedGraphId": "sidebar",
            "favorites": pages, "recentPages": recent, "outlinerRows": journalRows]
        let snapshot = String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { _ in snapshot }))
        try runtime.applyCoreResponse(snapshot)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
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
        let overlay = views(window).flatMap { $0.gestureRecognizers ?? [] }.contains { $0.name == "logseq.sidebar" }
        let journal = views(window).compactMap { $0 as? UIScrollView }.first {
            $0.contentSize.height > $0.bounds.height + 300 && $0.bounds.width > window.bounds.width / 2
        }
        journal?.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        try await Task.sleep(for: .milliseconds(250))
        let journalFrame = journal.map { $0.convert($0.bounds, to: window) }
        let journalOffset = journal?.contentOffset
        try backend.performPress(node: find("button.sidebar")!)
        try await Task.sleep(for: .milliseconds(700))
        guard let scroll = views(window).compactMap({ $0 as? UIScrollView }).first(where: {
            $0.contentSize.height > 3000 && $0.bounds.width < window.bounds.width * 0.85
        }) else { throw failure("Missing Recent/Favorites scroller") }
        print("SIDEBAR_SCROLL type=\(type(of: scroll)) size=\(scroll.contentSize) frame=\(scroll.frame) inset=\(scroll.adjustedContentInset)")
        let bottom = scroll.contentSize.height - scroll.bounds.height
        guard let settingsID = find("button.sidebar.settings"),
              let panelID = find("sidebar.navigation"), let panel = frames[panelID],
              let lastRecentID = find("link.sidebar.page.recent-39") else {
            throw failure("Missing sidebar footer or last Recent row")
        }
        func waitForSettingsToSettle() async throws {
            guard overlay else { return }
            let bottom = max(window.safeAreaInsets.bottom, LGNavigationSurfacePolicy.collapsedComposerCenterFromBottom - 22)
            for _ in 0..<50 {
                if let frame = frames[settingsID],
                   abs(window.bounds.maxX - frame.maxX - window.safeAreaInsets.right - 16) < 1,
                   abs(window.bounds.maxY - frame.maxY - bottom) < 1 { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure("Settings must settle at the bottom-right of the window")
        }
        try await waitForSettingsToSettle()
        guard let settings = frames[settingsID] else { throw failure("Missing Settings frame") }
        func settingsStayedInPlace() -> Bool {
            guard let actual = frames[settingsID] else { return false }
            return abs(actual.minX - settings.minX) < 1 && abs(actual.minY - settings.minY) < 1 && actual.size == settings.size
        }
        guard abs(scroll.convert(scroll.bounds, to: window).maxY - panel.maxY) < 1 else {
            throw failure("The sidebar scroll viewport must extend behind Settings to the bottom of the panel")
        }
        if overlay {
            guard let journal, journal.convert(journal.bounds, to: window) == journalFrame,
                  journal.contentOffset == journalOffset else { throw failure("Opening the overlay moved the journal") }
        }
        for offset: CGFloat in [0, 400, 2200, bottom] {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            try await Task.sleep(for: .milliseconds(200))
            guard abs(scroll.contentOffset.y - offset) < 1 else {
                throw failure("The fixture must reach the requested scroll position before toggling")
            }
            let sampler = SidebarScrollSampler(scroll: scroll)
            for selected in [false, true, false, true] {
                try backend.performToggle(node: drawer, checked: selected)
                try await Task.sleep(for: .milliseconds(500))
            }
            try await waitForSettingsToSettle()
            sampler.stop()
            print("SIDEBAR offset=\(offset) frames=\(sampler.frames) modelShift=\(sampler.maximumModelShift) displayedShift=\(sampler.maximumDisplayedShift) viewportShift=\(sampler.maximumViewportShift)")
            guard sampler.maximumModelShift < 1, sampler.maximumDisplayedShift < 1, sampler.maximumViewportShift < 1 else {
                throw failure("Drawer transforms must preserve the Recent/Favorites scroll viewport; offset=\(offset), displayed shift=\(sampler.maximumDisplayedShift), viewport shift=\(sampler.maximumViewportShift)")
            }
            guard scroll.isScrollEnabled, scroll.window === window else {
                throw failure("The retained sidebar must resume scrolling after transitions")
            }
            guard settingsStayedInPlace() else { throw failure("Settings must stay fixed while the sidebar scrolls") }
        }
        let viewport = scroll.convert(scroll.bounds, to: window)
        guard let lastRecent = frames[lastRecentID], lastRecent.minY >= viewport.minY,
              lastRecent.maxY <= settings.minY + 1 else {
            throw failure("The last Recent row must scroll fully above Settings")
        }
        guard runtime.lastError == nil else { throw failure(runtime.lastError!) }
        if overlay, let journal {
            guard let shell = backend.rootIDs.flatMap(descendants).first(where: {
                backend.extensionModel(id: $0)?.identifier == "sidebar-overlay"
            }) else { throw failure("Missing sidebar overlay") }
            // A reconciliation pass can publish IDs from a child it never mounts.
            let ops: [[String: Any]] = ["main-id", "panel-id", "settings-id"].map {
                ["op": "set-extension-prop", "id": shell, "property": $0, "value": Int32.max]
            }
            let batch = try JSONSerialization.data(withJSONObject: ["generation": backend.generation + 1, "ops": ops])
            try backend.apply(json: String(decoding: batch, as: UTF8.self))
            try await Task.sleep(for: .milliseconds(300))
            guard journal.window === window, scroll.window === window, settingsStayedInPlace() else {
                throw failure("An unmounted ID displaced the committed sidebar content")
            }
        }
        print("PASS: Recent/Favorites retain their displayed scroll position while toggling the sidebar")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SidebarScrollTransition", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
