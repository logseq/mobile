import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class ScrollingEditorEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct OutlinerScrollingEditorCheck {
    @MainActor static func main() async throws {
        let secret = "Diagnostic privacy fixture"
        let rows: [[String: Any]] = (0..<200).map { index in
            ["depth": index % 3, "hasChildren": index % 3 < 2, "isCollapsed": false,
             "block": ["uuid": "row-\(index)", "title": index == 8 ? secret : "Row \(index)", "pageId": "page"]]
        }
        func snapshot(_ editing: Bool) throws -> String {
            let result: [String: Any] = ["selectedGraphId": "demo", "graphName": "Demo", "outlinerRows": rows,
                "outlinerState": editing ? ["editing": ["uuid": "row-8", "title": secret, "caretUTF16Offset": 0]] : ["selectedBlockIds": []]]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: ScrollingEditorEffects())
        try runtime.applyCoreResponse(snapshot(false))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        try await Task.sleep(for: .milliseconds(500))
        try runtime.applyCoreResponse(snapshot(true))
        try await Task.sleep(for: .milliseconds(700))
        guard let editor = views(window).compactMap({ $0 as? UITextView }).first(where: { $0.isFirstResponder }) else {
            throw failure("The fixture must start with a real focused native editor")
        }
        var ancestor = editor.superview
        while ancestor != nil && !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
        let scroll = ancestor as! UIScrollView
        var lostFocus = false
        for y in stride(from: 0, through: 1600, by: 100) {
            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            try await Task.sleep(for: .milliseconds(70))
            if !editor.isFirstResponder { lostFocus = true }
        }
        for y in stride(from: 1600, through: 0, by: -100) {
            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            try await Task.sleep(for: .milliseconds(70))
            if !editor.isFirstResponder { lostFocus = true }
        }
        try await Task.sleep(for: .milliseconds(350))
        let log = try String(contentsOf: URL.cachesDirectory.appendingPathComponent("interaction-debug.log"), encoding: .utf8)
        guard log.contains("editor.make"), log.contains("frame"), log.contains("UIKeyboardWillChangeFrameNotification") else {
            throw failure("Device diagnostics must persist editor, geometry, and keyboard events")
        }
        guard !log.contains(secret) else { throw failure("Interaction diagnostics must never record note content") }
        guard !lostFocus else { throw failure("Scrolling away from and back to the edited block must not discard its first responder or flicker the keyboard") }
        print("PASS: scrolling preserves the native editor and diagnostics record geometry without note text")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "ScrollingEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
