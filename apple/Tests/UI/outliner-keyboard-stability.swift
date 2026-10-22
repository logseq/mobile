import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class KeyboardStabilityEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct OutlinerKeyboardStabilityCheck {
    @MainActor static func main() async throws {
        func snapshot(_ editing: Int?) throws -> String {
            func title(_ index: Int) -> String {
                index == 44 ? "Row 44\nSecond line\nThird line\nFourth line\nFifth line\nSixth line" : "Row \(index)"
            }
            let rows: [[String: Any]] = (0..<200).map { index in
                ["depth": index % 3, "hasChildren": index % 3 < 2, "isCollapsed": false,
                 "block": ["uuid": "row-\(index)", "title": title(index), "pageId": "page"]]
            }
            let result: [String: Any] = ["selectedGraphId": "demo", "graphName": "Demo",
                "outlinerRows": rows,
                "outlinerState": editing.map { ["editing": ["uuid": "row-\($0)", "title": title($0), "caretUTF16Offset": 0]] } ?? ["selectedBlockIds": []]]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: KeyboardStabilityEffects())
        try runtime.applyCoreResponse(snapshot(nil))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        try await Task.sleep(for: .milliseconds(700))
        let firstRow = views(window).first { $0.accessibilityIdentifier == "outliner.block-action.row-0" }!
        var ancestor = firstRow.superview
        while ancestor != nil && !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
        let scroll = ancestor as! UIScrollView
        scroll.setContentOffset(CGPoint(x: 0, y: 1100), animated: false)
        try await Task.sleep(for: .milliseconds(600))
        let originalOffset = scroll.contentOffset
        guard let anchor = views(window).first(where: { $0.accessibilityIdentifier == "outliner.block-action.row-40" }) else {
            let ids = views(window).compactMap(\.accessibilityIdentifier).filter { $0.hasPrefix("outliner.block-action") }
            throw failure("The scrolled anchor must be materialized; offset=\(scroll.contentOffset), size=\(scroll.contentSize), rows=\(ids)")
        }
        let originalAnchorY = anchor.convert(anchor.bounds, to: window).minY
        var failures: [String] = []
        for editing: Int? in [44, nil, 43, 44, 42, nil] {
            try runtime.applyCoreResponse(snapshot(editing))
            for _ in 0..<35 {
                try await Task.sleep(for: .milliseconds(16))
                if abs(scroll.contentOffset.y - originalOffset.y) > 1 {
                    failures.append("Editing \(String(describing: editing)) shifts the viewport from \(originalOffset.y) to \(scroll.contentOffset.y)")
                }
                if let anchor = views(window).first(where: { $0.accessibilityIdentifier == "outliner.block-action.row-40" }),
                   abs(anchor.convert(anchor.bounds, to: window).minY - originalAnchorY) > 1 {
                    failures.append("An unchanged visible row moved during keyboard presentation")
                }
                for editor in views(window).compactMap({ $0 as? UITextView }) where editor.isFirstResponder {
                    if !editor.text.contains("\n"), editor.bounds.height > 30 { failures.append("Single-line editor expanded to \(editor.bounds.height)") }
                }
                for guide in views(window).compactMap({ $0 as? OutlinerIndentGuideView }) where !guide.isHidden {
                    if let shape = guide.layer as? CAShapeLayer, let presented = shape.presentation(),
                       let path = presented.path, path.boundingBox.maxY > guide.bounds.height + 1 {
                        failures.append("A guide draws outside its row during editor handoff")
                    }
                }
            }
        }
        guard failures.isEmpty else { throw failure(failures.prefix(6).joined(separator: "; ")) }
        print("PASS: keyboard presentation, dismissal, and editor handoffs preserve the scrolled viewport and row heights")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "KeyboardStability", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
