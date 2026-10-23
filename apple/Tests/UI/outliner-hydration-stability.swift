import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class HydrationStabilityEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct OutlinerHydrationStabilityCheck {
    @MainActor static func main() async throws {
        func block(_ index: Int, shell: Bool) -> [String: Any] {
            ["uuid": "row-\(index)", "title": shell || index.isMultiple(of: 2) ? "" : "Row \(index)",
             "pageId": "page", "isShell": shell]
        }
        func snapshot(shell: Bool, patch: Bool = false) throws -> String {
            var result: [String: Any] = ["selectedGraphId": "demo", "graphName": "Demo"]
            if patch {
                result["isOutlinerContentPatch"] = true
                result["hydratedBlocks"] = (0..<100).map { block($0, shell: false) }
            } else {
                result["outlinerRows"] = (0..<100).map { ["depth": 0, "block": block($0, shell: shell && $0 >= 32)] }
                result["outlinerState"] = ["editing": ["uuid": "row-45", "title": "Row 45", "caretUTF16Offset": 0]]
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: HydrationStabilityEffects())
        try runtime.applyCoreResponse(snapshot(shell: false))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        try await Task.sleep(for: .milliseconds(700))
        let first = views(window).first { $0.accessibilityIdentifier == "outliner.block-action.row-0" }!
        var ancestor = first.superview
        while ancestor != nil && !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
        let scroll = ancestor as! UIScrollView
        scroll.setContentOffset(CGPoint(x: 0, y: 1050), animated: false)
        try await Task.sleep(for: .milliseconds(700))
        guard let editor = views(window).compactMap({ $0 as? UITextView }).first(where: { $0.isFirstResponder }) else {
            throw failure("The scrolled fixture must contain a native editor")
        }
        let originalY = editor.convert(editor.bounds, to: window).minY
        var positions: [CGFloat] = []
        for _ in 0..<5 {
            try runtime.applyCoreResponse(snapshot(shell: true))
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(16))
                positions.append(editor.convert(editor.bounds, to: window).minY)
            }
            try runtime.applyCoreResponse(snapshot(shell: false, patch: true))
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(16))
                positions.append(editor.convert(editor.bounds, to: window).minY)
            }
        }
        let drift = positions.map { abs($0 - originalY) }.max() ?? 0
        guard drift <= 1 else { throw failure("Unchanged empty blocks must retain geometry across shell snapshots and hydration; editor drifts \(drift)pt") }
        print("PASS: five shell/hydration cycles preserve empty blocks and editor geometry without flicker")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "HydrationStability", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
