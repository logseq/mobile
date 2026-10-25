import SwiftUI
import UIKit
@testable import Logseq

@main struct CodeEditorPresentationCheck {
    @MainActor static func main() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        func editor(_ policy: String) -> some View {
            OutlinerInlineEditor(text: "let value = 42\nvalue + 1", blockID: "code", desiredCaretUTF16Offset: 0,
                inputPolicy: policy, focusEnabled: false, onTextChange: { _, _ in }, onReturn: { _, _ in },
                onBackspace: { _, _ in }, onCaretChange: { _ in }).padding(16)
        }
        let host = UIHostingController(rootView: editor(#"{"multiline":true,"code":true}"#))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        for _ in 0..<100 {
            if views(window).contains(where: { $0 is UITextView }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let field = views(window).compactMap { $0 as? UITextView }.first!
        guard field.font?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true,
              field.autocorrectionType == .no, field.smartQuotesType == .no else {
            throw NSError(domain: "CodeEditorPresentation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Active code must use a monospaced font and literal input"])
        }
        let selected = field.selectedRange
        host.rootView = editor(#"{"multiline":false}"#)
        try await Task.sleep(for: .milliseconds(100))
        guard field.font?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == false,
              field.selectedRange == selected else { fatalError("Changing presentation must preserve the editor and caret") }
        print("PASS: code input uses native code styling and preserves the editor on presentation changes")
    }
}
