import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class CommandFormEffects: LGEffectExecuting {
    var submissions: [String] = []
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "editor-outliner-event" { submissions.append(effect.text) }
        return .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct EditorCommandFormFocusCheck {
    @MainActor static func main() async throws {
        func snapshot(_ kind: String?) throws -> String {
            var state: [String: Any] = ["editing": ["uuid": "editing", "title": "/", "caretUTF16Offset": 1]]
            if let kind { state["autocomplete"] = ["kind": kind, "query": ""] }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": [
                "selectedGraphId": "demo", "graphName": "Demo", "outlinerRows": [["depth": 0,
                    "block": ["uuid": "editing", "title": "/", "pageId": "page"]]], "outlinerState": state]]), as: UTF8.self)
        }
        let effects = CommandFormEffects()
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(snapshot(nil))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        let backend = runtime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier }
        }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure(message)
        }
        try await wait("The original block must be editing") {
            views(window).contains { ($0 as? UITextView)?.isFirstResponder == true }
        }
        let original = views(window).compactMap { $0 as? UITextView }.first { $0.isFirstResponder }!
        for kind in ["link", "image"] {
            try runtime.applyCoreResponse(snapshot(kind))
            try await wait("The command form must present") { window.rootViewController?.presentedViewController != nil }
            try await Task.sleep(for: .milliseconds(500))
            guard let url = views(window).compactMap({ $0 as? UITextField }).first(where: { $0.placeholder == "https://example.com" }),
                  let label = views(window).compactMap({ $0 as? UITextField }).first(where: { $0.placeholder == "Label (optional)" }) else {
                throw failure("The \(kind) form must contain native URL and label inputs")
            }
            for (field, value) in [(url, "https://example.com/image.png"), (label, "A useful label")] {
                guard field.becomeFirstResponder() else { throw failure("The native \(kind) input must accept taps") }
                field.insertText(value)
                try runtime.applyCoreResponse(snapshot(kind))
                try await Task.sleep(for: .milliseconds(250))
                guard field.isFirstResponder, field.text == value, !original.isFirstResponder else {
                    throw failure("The \(kind) form lost input focus to the block during a core update")
                }
            }
            try backend.performPress(node: find("button.outliner.autocomplete.submit")!)
            await runtime.drainEffectsForTesting()
            guard effects.submissions.contains(where: { $0.contains("https://example.com/image.png") && $0.contains("A useful label") }) else {
                throw failure("Insert must submit both typed values")
            }
            try runtime.applyCoreResponse(snapshot(nil))
            try await wait("Closing the form must restore the original editor and cursor") {
                window.rootViewController?.presentedViewController == nil && original.isFirstResponder
            }
        }
        print("PASS: Link and Image link forms accept native URL/label input across updates and restore block focus")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "CommandFormFocus", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
