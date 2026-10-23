import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class BoundaryEffects: LGEffectExecuting {
    var response = ""
    var reject = false
    var backspaces = 0
    var typed: [String] = []
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "backspace-outliner-editor" {
            backspaces += 1
            try? await Task.sleep(for: .milliseconds(200))
            return reject
                ? .init(succeeded: false, message: "Operation rejected", output: .discard)
                : .init(succeeded: true, message: response, output: .coreResponse)
        }
        if effect.kind == "change-outliner-text" { typed.append(effect.text) }
        return .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct OutlinerBackspaceBoundaryCheck {
    @MainActor static func main() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func snapshot(_ title: String) throws -> String {
            let result: [String: Any] = ["selectedGraphId": "demo", "graphName": "Demo",
                "outlinerRows": [["depth": 0, "block": ["uuid": "first", "title": title,
                    "pageId": "journal", "journalDay": 20261024, "journalTitle": "Today"]]],
                "outlinerState": ["editing": ["uuid": "first", "title": title, "caretUTF16Offset": 0]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        for (title, reject) in [("Hello", false), ("", false), ("日本語 🙂", false), ("Hello", true)] {
            let effects = BoundaryEffects()
            effects.response = try snapshot(title)
            effects.reject = reject
            let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
            try runtime.applyCoreResponse(snapshot(title))
            try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
            try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
            window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(400))
            guard let editor = views(window).compactMap({ $0 as? UITextView }).first(where: {
                $0.accessibilityIdentifier == "field.outliner.block.first"
            }), editor.isFirstResponder else { throw failure("The first journal block must have a focused editor") }
            editor.selectedRange = NSRange(location: 0, length: 0)
            guard editor.delegate?.textView?(editor, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "") == false else {
                throw failure("Boundary backspace must be handled as a structural editor event")
            }
            func type(_ text: String) {
                if editor.delegate?.textView?(editor, shouldChangeTextIn: editor.selectedRange, replacementText: text) != false {
                    editor.insertText(text)
                }
            }
            // Input arriving during an unchanged render must survive the structural acknowledgement.
            try runtime.applyCoreResponse(snapshot(title))
            type("新🙂")
            await runtime.drainEffectsForTesting()
            try await Task.sleep(for: .milliseconds(350))
            await runtime.drainEffectsForTesting()
            guard effects.backspaces == 1 else { throw failure("Expected exactly one native boundary backspace; got \(effects.backspaces)") }
            guard editor.text == "新🙂" + title, editor.isFirstResponder,
                  editor.selectedRange.location == "新🙂".utf16.count else {
                throw failure("Typing after a boundary backspace must be visible without Enter: title=\(title), reject=\(reject), text=\(editor.text ?? "nil")")
            }
            type("x")
            await runtime.drainEffectsForTesting()
            guard editor.text == "新🙂x" + title, effects.typed.contains("新🙂x" + title) else {
                throw failure("Typing must continue and reach the core after the no-op is acknowledged")
            }
            runtime.stop()
            window.rootViewController = nil
        }
        window.isHidden = true
        print("PASS: journal boundary backspace preserves visible typing and focus, including empty, Unicode and rejected requests")
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "BackspaceBoundary", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
