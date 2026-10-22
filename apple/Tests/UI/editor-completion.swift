import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class EditorCompletionEffects: LGEffectExecuting {
    var response = ""
    var choices = 0
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "choose-outliner-autocomplete" {
            choices += 1
            return .init(succeeded: true, message: response, output: .coreResponse)
        }
        return .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct EditorCompletionCheck {
    @MainActor static func main() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func snapshot(_ title: String, caret: Int, kind: String?, label: String, value: String) throws -> String {
            var state: [String: Any] = ["editing": ["uuid": "editing", "title": title, "caretUTF16Offset": caret], "selectedBlockIds": []]
            if let kind { state["autocomplete"] = ["kind": kind, "query": ""] }
            var candidate: [String: Any] = ["label": label, "value": value]
            if kind == "command" { candidate["group"] = "FORMAT" }
            let result: [String: Any] = ["selectedGraphId": "demo", "graphName": "Demo",
                "outlinerRows": [["depth": 0, "block": ["uuid": "editing", "title": title, "pageId": "page"]]],
                "outlinerState": state, "outlinerAutocompleteCandidates": kind == nil ? [] : [candidate]]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        for (kind, before, after, caret, label, value) in [
            ("command", "🙂 /", "🙂 <ins></ins>", 8, "Underline", "command:underline"),
            ("node", "[[Pro", "[[Project]]", 11, "Project", "project"),
            ("tag", "Text #Pro", "Text", 4, "Project", "project")
        ] {
            let effects = EditorCompletionEffects()
            effects.response = try snapshot(after, caret: caret, kind: nil, label: label, value: value)
            let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
            try runtime.applyCoreResponse(snapshot(before, caret: before.utf16.count, kind: kind, label: label, value: value))
            try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
            try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
            window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(700))
            await runtime.drainEffectsForTesting()
            try runtime.applyCoreResponse(snapshot(before, caret: before.utf16.count, kind: kind, label: label, value: value))
            try await Task.sleep(for: .milliseconds(200))
            let backend = runtime.renderer.backend
            func nodes(_ id: Int) -> [Int] {
                [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(nodes)
            }
            let all = backend.rootIDs.flatMap(nodes)
            func node(_ identifier: String) -> Int? {
                all.first { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier }
            }
            if kind == "command", node("outliner.autocomplete.group.FORMAT") == nil { throw failure("Command group heading is missing") }
            guard node("button.outliner.autocomplete.dismiss") != nil,
                  let candidate = node("button.outliner.autocomplete.0") else { throw failure("Missing shared panel for \(kind)") }
            try backend.performPress(node: candidate)
            await runtime.drainEffectsForTesting()
            try await Task.sleep(for: .milliseconds(400))
            guard effects.choices == 1,
                  let editor = views(window).compactMap({ $0 as? UITextView }).first(where: { $0.text == after }),
                  editor.selectedRange.location == caret, editor.isFirstResponder else {
                throw failure("Selecting \(kind) must preserve the editor and apply its caret")
            }
            runtime.stop()
            window.rootViewController = nil
        }
        var pasted: [String] = []
        window.rootViewController = UIHostingController(rootView: OutlinerInlineEditor(
            text: "", blockID: "paste", desiredCaretUTF16Offset: 0,
            onTextChange: { _, _ in }, onPaste: { title, _ in pasted.append(title) },
            onReturn: { _, _ in }, onBackspace: { _, _ in }, onCaretChange: { _ in }))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(300))
        let editor = views(window).compactMap { $0 as? UITextView }.first!
        UIPasteboard.general.string = "Pasted text /"
        editor.paste(nil)
        try await Task.sleep(for: .milliseconds(500))
        guard pasted == ["Pasted text /"] else {
            throw failure("Native paste must be distinguished from typing: \(pasted), text: \(editor.text ?? "nil")")
        }
        print("PASS: commands, pages and tags share a panel, preserve keyboard/caret, and native paste is explicit")
        window.isHidden = true
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "EditorCompletion", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
