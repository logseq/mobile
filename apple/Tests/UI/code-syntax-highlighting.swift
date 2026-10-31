import SwiftUI
import UIKit
import LogseqModel
@testable import Logseq

@main struct CodeSyntaxHighlightingCheck {
    @MainActor static func main() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        for (language, source, words) in [
            ("clojure", "(def answer 42)\n(defn square [x] (* x x)) ; 😀", ["def", "defn"]),
            ("ml", "let square x = x * x\n(* nested (* comment *) *)\ntype point = { x : float }", ["let", "type"])
        ] {
            let tokens = await CodeSyntaxHighlighter.shared.tokens(code: source, language: language)
            let preview = NSAttributedString(NativeCodeHighlighting.attributed(source, tokens: tokens))
            guard preview.string == source else { fatalError("Code previews must preserve the source verbatim") }
            for word in words {
                let offset = (source as NSString).range(of: word).location
                guard let color = preview.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor,
                      color != UIColor.label else { fatalError("\(language): preview must highlight \(word)") }
            }
            let policy = "{\"multiline\":true,\"code\":true,\"language\":\"\(language)\"}"
            let host = UIHostingController(rootView: OutlinerInlineEditor(text: source, blockID: language,
                desiredCaretUTF16Offset: 5, inputPolicy: policy, focusEnabled: false,
                onTextChange: { _, _ in }, onReturn: { _, _ in }, onBackspace: { _, _ in }, onCaretChange: { _ in }))
            window.rootViewController = host
            window.makeKeyAndVisible()
            var field: UITextView?
            for _ in 0..<100 {
                field = views(window).compactMap { $0 as? UITextView }.first
                if let field, words.allSatisfy({ word in
                    let offset = (source as NSString).range(of: word).location
                    return field.textStorage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor != UIColor.label
                }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let field else { fatalError("Missing native code editor") }
            for word in words {
                let offset = (source as NSString).range(of: word).location
                guard let color = field.textStorage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor,
                      color != UIColor.label else { fatalError("\(language): \(word) must have syntax highlighting while editing") }
            }
            guard field.text == source, field.selectedRange == NSRange(location: 5, length: 0) else {
                fatalError("Highlighting must preserve source and selection")
            }
            field.selectedRange = NSRange(location: 0, length: 0)
            field.insertText("; 😀\n")
            try await Task.sleep(for: .milliseconds(200))
            guard field.text == "; 😀\n" + source, field.selectedRange.location == 5 else {
                fatalError("Typing and UTF-16 selection must survive asynchronous highlighting")
            }
            if language == "clojure" {
                let actual = (field.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)?
                    .resolvedColor(with: field.traitCollection)
                guard actual == NativeCodeHighlighting.color("comment").resolvedColor(with: field.traitCollection) else {
                    fatalError("Newly typed Clojure comments must be highlighted live")
                }
            }
        }
        print("PASS: native Clojure and OCaml previews and editors highlight definitions without changing text or selection")
    }
}
