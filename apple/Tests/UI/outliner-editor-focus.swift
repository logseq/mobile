import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class FocusEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct OutlinerEditorFocusCheck {
    @MainActor static func main() async throws {
        func snapshot(selectedPage: Bool, editing: Bool) throws -> String {
            var result: [String: Any] = ["selectedGraphId": "demo", "graphName": "Demo",
                "outlinerRows": [["depth": 0, "block": ["uuid": "target", "title": "Hello world",
                    "pageId": "journal", "journalDay": 20261023, "journalTitle": "Today"]]],
                "outlinerState": editing ? ["editing": ["uuid": "target", "title": "Hello world", "caretUTF16Offset": 11]] : ["selectedBlockIds": []]]
            if selectedPage { result["selectedPage"] = ["uuid": "journal", "title": "Today"] }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: FocusEffects())
        try runtime.applyCoreResponse(snapshot(selectedPage: false, editing: false))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer).ignoresSafeArea(.keyboard))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func editors() -> [UITextView] { views(window).compactMap { $0 as? UITextView }.filter {
            $0.accessibilityIdentifier == "field.outliner.block.target"
        } }
        try await Task.sleep(for: .milliseconds(400))
        for selectedPage in [false, true] {
            try runtime.applyCoreResponse(snapshot(selectedPage: selectedPage, editing: true))
            try await Task.sleep(for: .milliseconds(450))
            guard editors().count == 1, let editor = editors().first else {
                throw failure("Expected one editor in selectedPage=\(selectedPage); found \(editors().count)")
            }
            guard editor.isFirstResponder else { throw failure("The visible editor must own the insertion cursor") }
            for offset in [2, 7, 0] {
                editor.selectedRange = NSRange(location: offset, length: 0)
                editor.delegate?.textViewDidChangeSelection?(editor)
                // A repeated core acknowledgement must not restore the old end-of-block caret.
                try runtime.applyCoreResponse(snapshot(selectedPage: selectedPage, editing: true))
                try await Task.sleep(for: .milliseconds(150))
                guard editors().count == 1, editors().first === editor, editor.isFirstResponder,
                      editor.selectedRange == NSRange(location: offset, length: 0) else {
                    throw failure("A caret tap at \(offset) lost focus, identity or position in selectedPage=\(selectedPage)")
                }
            }
        }
        print("PASS: retained journal and selected page keep one focused editor and preserve native caret taps")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "EditorFocus", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
