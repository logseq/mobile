import SwiftUI
import UIKit
@testable import Logseq

@main struct CheckBlockDisclosureEdge {
    @MainActor static func main() async throws {
        func snapshot(collapsed: Bool) throws -> String {
            func block(_ uuid: String, _ title: String) -> [String: Any] {
                ["uuid": uuid, "title": title, "pageId": "today",
                 "journalTitle": "Nov 24th, 2026", "journalDay": 20261124]
            }
            var rows: [[String: Any]] = [
                ["block": block("parent", "Tabs"), "depth": 0, "hasChildren": true, "isCollapsed": collapsed]
            ]
            if !collapsed { rows.append(["block": block("child", "Journals"), "depth": 1]) }
            let result: [String: Any] = ["graphName": "Work", "selectedGraphId": "work", "outlinerRows": rows]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }

        let collapsedSnapshot = try snapshot(collapsed: true)
        let expandedSnapshot = try snapshot(collapsed: false)
        var collapsed = true
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { request in
            if let data = request.params.payload?.data(using: .utf8),
               let effect = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               effect["kind"] as? String == "toggle-outliner-collapsed", effect["text"] as? String == "parent" {
                collapsed.toggle()
            }
            return collapsed ? collapsedSnapshot : expandedSnapshot
        }))
        try runtime.applyCoreResponse(collapsedSnapshot)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true }

        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func control(_ identifier: String) -> UIView? {
            views(window).first { $0.accessibilityIdentifier == identifier && !$0.isHidden }
        }

        try await Task.sleep(for: .milliseconds(700))
        for initiallyCollapsed in [true, false] {
            guard collapsed == initiallyCollapsed,
                  let disclosure = control("button.outliner.collapse.parent") as? UIButton,
                  let arrow = disclosure.imageView else { throw failure("Missing disclosure control") }
            let arrowFrame = arrow.convert(arrow.bounds, to: window)
            // On a compact viewport, the existing row margin and glyph inset leave 14 points.
            let gap = window.bounds.maxX - arrowFrame.maxX
            guard abs(gap - 14) <= 1 else { throw failure("Unexpected arrow inset: \(gap)") }
            for distance: CGFloat in [12, 6, 2] {
                for offset: CGFloat in [-6, 0, 6] {
                    let point = CGPoint(x: window.bounds.maxX - distance, y: arrowFrame.midY + offset)
                    guard window.hitTest(point, with: nil) === disclosure else {
                        throw failure("The disclosure missed a tap \(distance) points from the trailing edge at y=\(point.y)")
                    }
                }
            }

            disclosure.sendActions(for: .touchUpInside)
            await runtime.drainEffectsForTesting()
            try await Task.sleep(for: .milliseconds(350))
            let child = control("outliner.block-action.child")
            guard collapsed != initiallyCollapsed,
                  (child != nil) == initiallyCollapsed else {
                throw failure("The edge target must toggle the block's child visibility")
            }
            if let child {
                let trailingGap = window.bounds.maxX - child.convert(child.bounds, to: window).maxX
                guard abs(trailingGap - 8) <= 1 else { throw failure("Unexpected leaf content inset: \(trailingGap)") }
            }
        }
        print("PASS: the Journal disclosure hits the trailing gutter and toggles in both directions")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "BlockDisclosureEdge", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
