import SwiftUI
import UIKit
import WebKit
@testable import Logseq
@testable import LUIAppleBackend

@MainActor private final class SpecialBlockEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct SpecialBlockPresentationCheck {
    @MainActor static func main() async throws {
        func snapshot(editing: String? = nil) throws -> String {
            var rows: [[String: Any]] = [
                ["depth": 0, "block": ["uuid": "text", "pageId": "page", "title": "Ordinary text remains visible",
                    "markup": [["type": "text", "text": "Ordinary text remains visible"]]]],
                ["depth": 0, "block": ["uuid": "math", "pageId": "page", "title": "x^2", "displayType": "math",
                    "markup": [["type": "math", "style": "display", "text": "x^2"]]]],
                ["depth": 0, "block": ["uuid": "code", "pageId": "page", "title": "let x = 42", "displayType": "code",
                    "markup": [["type": "codeBlock", "style": "ocaml", "text": "let x = 42"]]]],
            ]
            if editing == "next" {
                rows.append(["depth": 0, "block": ["uuid": "next", "pageId": "page", "title": "", "markup": []]])
            }
            var state: [String: Any] = [:]
            if let editing {
                let title = editing == "code" ? "let x = 42" : (editing == "next" ? "" : "x^2")
                state["editing"] = ["uuid": editing, "title": title, "caretUTF16Offset": title.utf16.count]
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": [
                "selectedGraphId": "demo", "graphName": "Special block regression",
                "selectedPage": ["uuid": "page", "title": "Code and math"],
                "outlinerRows": rows, "outlinerState": state]]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: SpecialBlockEffects())
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true; window.rootViewController = nil }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "SpecialBlockPresentation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        for editing in [nil, "math", nil] as [String?] {
            try runtime.applyCoreResponse(snapshot(editing: editing))
            try await wait("Ordinary text must remain visible beside code and math") {
                views(window).compactMap { $0 as? UILabel }.contains { $0.text == "Ordinary text remains visible" || $0.attributedText?.string == "Ordinary text remains visible" }
            }
            if editing == nil {
                try await wait("A math preview must mount its formula renderer rather than an empty editor placeholder") {
                    views(window).contains { $0 is WKWebView && $0.bounds.width > 100 && $0.bounds.height > 0 }
                }
                var rendered = false
                for _ in 0..<100 {
                    if let web = views(window).compactMap({ $0 as? WKWebView }).first,
                       let count = try? await web.evaluateJavaScript("document.querySelectorAll('.katex').length") as? Int,
                       count == 1 {
                        rendered = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard rendered else {
                    throw NSError(domain: "SpecialBlockPresentation", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "A mounted math preview must render its formula"])
                }
            } else {
                try await wait("Tapping a math block must still mount its native editor") {
                    views(window).compactMap { $0 as? UITextView }.contains { $0.accessibilityIdentifier == "field.outliner.block.math" }
                }
            }
        }
        for editing in ["code", "next"] {
            try runtime.applyCoreResponse(snapshot(editing: editing))
            try await wait("Changing from a code editor to a new plain block must transfer keyboard focus") {
                views(window).compactMap { $0 as? UITextView }.contains {
                    $0.accessibilityIdentifier == "field.outliner.block." + editing && $0.isFirstResponder
                        && $0.bounds.width > 100 && $0.bounds.height > 0
                }
            }
        }
        print("PASS: ordinary text, code and math previews survive editor mounting and removal")
    }
}
