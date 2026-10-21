import UIKit
import SwiftUI
@testable import LUIAppleBackend
@testable import Logseq

@main struct ScrollingNavigationTitleCheck {
    @MainActor static func main() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        for isPage in [false, true] {
            let title = isPage ? "Project page" : "Oct 21st, 2026"
            let rows: [[String: Any]] = (0..<60).map { index in
                var block: [String: Any] = ["uuid": "row-\(index)", "title": "Body row \(index)", "pageId": "page"]
                if !isPage { block["journalTitle"] = title; block["journalDay"] = 20261021 }
                return ["block": block, "depth": 0]
            }
            var result: [String: Any] = ["graphName": "Work", "selectedGraphId": "work", "outlinerRows": rows,
                "outlinerState": ["selectedBlockIds": []]]
            if isPage { result["selectedPage"] = ["uuid": "page", "title": title] }
            let snapshot = String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
            let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { _ in snapshot }))
            try runtime.applyCoreResponse(snapshot)
            try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
            try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
            var observed: String?
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer)
                .onPreferenceChange(LUIScrollTitlePreferenceKey.self) { observed = $0 }
                .transaction { $0.disablesAnimations = true; $0.animation = nil })
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(1000))
            func scrollViews(_ view: UIView) -> [UIScrollView] {
                (view as? UIScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
            }
            guard let scroll = scrollViews(window).first(where: {
                guard $0.contentSize.height > $0.bounds.height + 300, $0.bounds.height > 200 else { return false }
                let center = $0.convert(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: window)
                var hit = window.hitTest(center, with: nil)
                while let view = hit {
                    if view === $0 { return true }
                    hit = view.superview
                }
                return false
            }) else { throw failure("Missing native outliner scroll view") }
            guard observed == nil else { throw failure("The toolbar title must stay hidden while its content heading is visible") }
            let top = -scroll.adjustedContentInset.top
            scroll.setContentOffset(CGPoint(x: 0, y: top + 180), animated: false)
            try await Task.sleep(for: .milliseconds(700))
            guard observed == title else { throw failure("The title must appear after its heading crosses the viewport top") }
            scroll.setContentOffset(CGPoint(x: 0, y: top), animated: false)
            try await Task.sleep(for: .milliseconds(700))
            guard observed == nil else { throw failure("Returning to the content heading must clear the toolbar title") }
            window.isHidden = true
            window.rootViewController = nil
            runtime.stop()
        }
        print("PASS: journal and page titles appear only after their headings scroll above the viewport, and clear on return")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "ScrollingNavigationTitle", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
