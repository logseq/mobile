import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class KeyboardStabilityEffects: LGEffectExecuting {
    var dismissedSnapshot = ""

    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "outliner-toolbar", effect.text == "hideKeyboard" {
            return .init(succeeded: true, message: dismissedSnapshot, output: .coreResponse)
        }
        return .init(succeeded: true, message: "", output: .discard)
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
        let effects = KeyboardStabilityEffects()
        effects.dismissedSnapshot = try snapshot(nil)
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(effects.dismissedSnapshot)
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
        guard let anchor = views(window).first(where: { $0.accessibilityIdentifier == "outliner.block-action.row-40" }) else {
            let ids = views(window).compactMap(\.accessibilityIdentifier).filter { $0.hasPrefix("outliner.block-action") }
            throw failure("The scrolled anchor must be materialized; offset=\(scroll.contentOffset), size=\(scroll.contentSize), rows=\(ids)")
        }
        let originalAnchorY = anchor.convert(anchor.bounds, to: window).minY
        let backend = runtime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? [])
                .flatMap(descendants)
        }
        func dismissKeyboard() throws {
            guard let dismiss = backend.rootIDs.flatMap(descendants).first(where: {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == "button.outliner.editor.hideKeyboard"
            }) else { throw failure("Missing the editor's Hide keyboard action") }
            try backend.performPress(node: dismiss)
        }
        var failures: [String] = []
        for editing: Int? in [44, nil, 43, 44, 42, nil] {
            if editing == nil {
                try dismissKeyboard()
            } else {
                try runtime.applyCoreResponse(snapshot(editing))
            }
            for frame in 0..<35 {
                try await Task.sleep(for: .milliseconds(16))
                if editing != nil || frame >= 2 {
                    let current = views(window).first { $0.accessibilityIdentifier == "outliner.block-action.row-40" }
                    if current.map({ abs($0.convert($0.bounds, to: window).minY - originalAnchorY) <= 1 }) != true {
                        failures.append("An unchanged visible row moved while editing \(String(describing: editing))")
                    }
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
        let regularInset = scroll.adjustedContentInset.bottom
        func regularEnd() -> CGFloat { scroll.contentSize.height - scroll.bounds.height + regularInset }
        for _ in 0..<3 {
            scroll.setContentOffset(CGPoint(x: 0, y: regularEnd()), animated: false)
            try await Task.sleep(for: .milliseconds(250))
        }
        let editableRow = views(window).first { view in
            let frame = view.convert(view.bounds, to: window)
            return view.accessibilityIdentifier?.hasPrefix("outliner.block-action.row-") == true
                && (360..<500).contains(frame.minY)
        }
        guard let identifier = editableRow?.accessibilityIdentifier,
              let index = Int(identifier.dropFirst("outliner.block-action.row-".count)) else {
            throw failure("Expected a visible row near the end of the page")
        }
        try runtime.applyCoreResponse(snapshot(index))
        try await Task.sleep(for: .milliseconds(650))
        guard scroll.adjustedContentInset.bottom > regularInset + 100 else {
            throw failure("The bottom-of-page check requires the docked software keyboard")
        }
        scroll.setContentOffset(CGPoint(x: 0, y: regularEnd() + 75), animated: false)
        try await Task.sleep(for: .milliseconds(300))
        guard let row = views(window).first(where: { view in
            let id = view.accessibilityIdentifier ?? ""
            return id.hasPrefix("outliner.block-action.row-") && id != identifier
                && (145..<325).contains(view.convert(view.bounds, to: window).minY)
        }), let rowID = row.accessibilityIdentifier else {
            throw failure("Expected a visible anchor row above the keyboard")
        }
        let rowY = row.convert(row.bounds, to: window).minY
        try dismissKeyboard()
        try await Task.sleep(for: .milliseconds(650))
        guard let after = views(window).first(where: { $0.accessibilityIdentifier == rowID }),
              abs(after.convert(after.bounds, to: window).minY - rowY) <= 1,
              !views(window).compactMap({ $0 as? UITextView }).contains(where: \.isFirstResponder) else {
            throw failure("Closing the keyboard near the end must preserve the visible row")
        }
        print("PASS: keyboard presentation, dismissal, and editor handoffs preserve the scrolled viewport and row heights")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "KeyboardStability", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
