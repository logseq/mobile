import SwiftUI
import UIKit
import LogseqModel
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class ClipboardEffects: LGEffectExecuting {
    var received: [[String: Any]] = []
    var typed: [String] = []
    var response = ""
    var succeeds = true
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "change-outliner-text" { typed.append(effect.text) }
        if effect.kind == "editor-outliner-event",
           let data = effect.text.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           payload["type"] as? String == "pasteContent" {
            received.append(payload)
            try? await Task.sleep(for: .milliseconds(300))
            return .init(succeeded: succeeds, message: succeeds ? response : "Storage failed",
                         output: succeeds ? .coreResponse : .discard)
        }
        return .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct OutlinerClipboardCheck {
    @MainActor static func main() async throws {
        let rich = "{:graph \"demo\" :op :copy :blocks [{:block/uuid #uuid \"10000000-0000-4000-8000-000000000004\" :block/title \"Alpha\"}]}"
        let plain = "- Alpha\n"
        var errors: [String] = []
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["plainText": plain, "blocksEDN": rich]), as: UTF8.self)
        UIPasteboard.general.string = "Unrelated prior clipboard"
        let router = LGPlatformCommandRouter(setClipboardText: { UIPasteboard.general.string = $0 },
                                             performHaptic: { _ in }, present: { _ in })
        router.handle(LGPlatformCommandBatch(revision: 1, graphName: "demo", commands: [
            LogseqOutlinerCommand(type: "setClipboardBlocks", style: nil, uuid: nil, uuids: nil, text: payload)
        ]))
        if UIPasteboard.general.string != plain ||
            UIPasteboard.general.data(forPasteboardType: "com.logseq.blocks") != Data(rich.utf8) {
            errors.append("Copy must write the Markdown and EDN to the same native clipboard item")
        }
        router.handle(LGPlatformCommandBatch(revision: 2, graphName: "demo", commands: [
            LogseqOutlinerCommand(type: "setClipboardText", style: nil, uuid: nil, uuids: nil, text: "New ordinary text")
        ]))
        if UIPasteboard.general.data(forPasteboardType: "com.logseq.blocks") != nil {
            errors.append("Ordinary Copy must invalidate the previous rich block snapshot")
        }

        func snapshot(uuid: String, title: String, caret: Int) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": [
                "selectedGraphId": "demo", "graphName": "Demo", "outlinerRows": [
                    ["depth": 0, "block": ["uuid": "editing", "title": uuid == "editing" ? title : "Keep original", "pageId": "page"]],
                    ["depth": 0, "block": ["uuid": "inserted", "title": uuid == "inserted" ? title : "Destination", "pageId": "page"]]],
                "outlinerState": ["editing": ["uuid": uuid, "title": title, "caretUTF16Offset": caret], "selectedBlockIds": []]
            ]]), as: UTF8.self)
        }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func type(_ text: String, into editor: UITextView) {
            if editor.delegate?.textView?(editor, shouldChangeTextIn: editor.selectedRange, replacementText: text) ?? true {
                editor.insertText(text)
            }
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        for kind in ["blocks", "inline", "failure"] {
            let effects = ClipboardEffects()
            let before = kind == "inline" ? "A😀Z" : "Keep original"
            effects.succeeds = kind != "failure"
            effects.response = try snapshot(uuid: kind == "blocks" ? "inserted" : "editing",
                                            title: kind == "blocks" ? "Alpha" : "AXZ", caret: kind == "blocks" ? 5 : 2)
            let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
            try runtime.applyCoreResponse(snapshot(uuid: "editing", title: before, caret: kind == "inline" ? 1 : before.utf16.count))
            try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
            try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(500))
            guard let editor = views(window).compactMap({ $0 as? UITextView }).first(where: { $0.isFirstResponder }) else {
                throw failure("Missing native clipboard target")
            }
            let selection = kind == "inline" ? NSRange(location: 1, length: 2) : NSRange(location: before.utf16.count, length: 0)
            editor.selectedRange = selection
            if kind == "blocks" {
                UIPasteboard.general.items = [["public.utf8-plain-text": Data(plain.utf8), "com.logseq.blocks": Data(rich.utf8)]]
            } else { UIPasteboard.general.string = "X" }
            editor.paste(nil)
            if editor.text != before { errors.append("\(kind): paste must retain the old block until the shared core answers") }
            type("Y", into: editor)
            // Let the single production effect drain own the acknowledgement.
            try await Task.sleep(for: .milliseconds(1400))
            guard let received = effects.received.first else {
                errors.append("\(kind): native Paste must transport its raw clipboard and pre-paste selection")
                window.isHidden = true; runtime.stop(); continue
            }
            if effects.received.count != 1 || received["beforeTitle"] as? String != before ||
                received["selectionStart"] as? Int != selection.location || received["selectionLength"] as? Int != selection.length ||
                received["plainText"] as? String != (kind == "blocks" ? plain : "X") ||
                received["blocksEDN"] as? String != (kind == "blocks" ? rich : "") {
                errors.append("\(kind): clipboard data changed while crossing the native/core bridge")
            }
            let expected = kind == "blocks" ? "AlphaY" : kind == "inline" ? "AXYZ" : "Keep originalY"
            guard let final = views(window).compactMap({ $0 as? UITextView }).first(where: { $0.isFirstResponder }) else {
                errors.append("\(kind): Paste lost keyboard focus"); window.isHidden = true; runtime.stop(); continue
            }
            if final !== editor || final.text != expected {
                errors.append("\(kind): rapid typing must follow the acknowledgement without losing the editor: \(final.text ?? "nil")")
            }
            type("Z", into: final)
            try await Task.sleep(for: .milliseconds(250))
            if !effects.typed.contains(expected + "Z") { errors.append("\(kind): editing remains blocked after paste completes") }
            window.isHidden = true; runtime.stop()
        }
        if !errors.isEmpty { throw failure(errors.joined(separator: "\n")) }
        print("PASS: native block clipboard, pre-paste selection, same/different block acknowledgements, fast typing and storage failure recovery")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "OutlinerClipboard", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
