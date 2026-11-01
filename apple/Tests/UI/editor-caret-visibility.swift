import SwiftUI
import UIKit
@testable import Logseq

@MainActor @Observable private final class EditingDraft {
    var text = "Start"
    var blockID = "first"
    var selectionRevision = 0
    var toolbarFrame = CGRect.zero
}

private struct CaretVisibilityFixture: View {
    @Bindable var draft: EditingDraft
    let code: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Before the editor").frame(height: 160)
                OutlinerInlineEditor(text: draft.text, blockID: draft.blockID,
                    desiredCaretUTF16Offset: draft.text.utf16.count,
                    inputPolicy: code ? #"{"code":true,"multiline":true}"# : "{}",
                    selectionRevision: draft.selectionRevision,
                    onTextChange: { text, _ in draft.text = text },
                    onReturn: { _, _ in
                        draft.blockID = UUID().uuidString
                        draft.selectionRevision += 1
                        draft.text = ""
                    },
                    onBackspace: { _, _ in }, onCaretChange: { _ in })
                Text("After the editor").frame(height: 800)
            }.padding(.horizontal, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text("Editing toolbar").frame(maxWidth: .infinity).frame(height: 56).background(.gray)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { draft.toolbarFrame = $0 }
        }
        .frame(width: 320, height: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@main struct EditorCaretVisibilityCheck {
    @MainActor static func main() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        for code in [true, false] {
            let draft = EditingDraft()
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: CaretVisibilityFixture(draft: draft, code: code))
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
            try await Task.sleep(for: .milliseconds(700))
            guard let field = views(window).compactMap({ $0 as? UITextView }).first,
                  field.isFirstResponder else { throw failure("Missing focused native editor") }
            var parent = field.superview
            while parent != nil && !(parent is UIScrollView) { parent = parent?.superview }
            guard let scroll = parent as? UIScrollView else { throw failure("Missing enclosing native scroll view") }
            for line in 0..<24 {
                field.insertText(code ? "\nLine \(line)" : " Words that wrap onto the next line.")
                try await Task.sleep(for: .milliseconds(120))
                window.layoutIfNeeded()
                guard let selection = field.selectedTextRange else { throw failure("Missing caret") }
                let caret = field.convert(field.caretRect(for: selection.end), to: scroll)
                let viewport = scroll.bounds.inset(by: scroll.adjustedContentInset)
                let windowCaret = field.convert(field.caretRect(for: selection.end), to: window)
                guard caret.maxY <= viewport.maxY + 1 && caret.minY >= viewport.minY - 1,
                      windowCaret.maxY <= draft.toolbarFrame.minY - 4 else {
                    throw failure("Typing must keep the caret above the toolbar: code=\(code) line=\(line) caret=\(caret) viewport=\(viewport)")
                }
            }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: 0), animated: false)
            try await Task.sleep(for: .milliseconds(180))
            guard abs(scroll.contentOffset.y) < 1 else {
                throw failure("Manual scrolling must not snap back to an unchanged caret")
            }
            field.selectedRange = NSRange(location: 0, length: 0)
            field.selectedRange = NSRange(location: field.text.utf16.count, length: 0)
            try await Task.sleep(for: .milliseconds(180))
            let selectedCaret = field.convert(field.caretRect(for: field.selectedTextRange!.end), to: window)
            guard selectedCaret.maxY <= draft.toolbarFrame.minY - 4 else {
                throw failure("Moving the caret must reveal it above the toolbar")
            }
            if !code {
                for _ in 0..<3 {
                    if field.delegate?.textView?(field, shouldChangeTextIn: field.selectedRange, replacementText: "\n") ?? true {
                        field.insertText("\n")
                    }
                    try await Task.sleep(for: .milliseconds(200))
                    guard field.isFirstResponder, field.text.isEmpty else { throw failure("New-block handoff must preserve the native editor: focused=\(field.isFirstResponder) length=\(field.text.utf16.count)") }
                    field.insertText("A new block")
                    try await Task.sleep(for: .milliseconds(150))
                    let caret = field.convert(field.caretRect(for: field.selectedTextRange!.end), to: scroll)
                    guard caret.maxY <= scroll.bounds.inset(by: scroll.adjustedContentInset).maxY + 1 else {
                        throw failure("New-block handoff must reveal the caret")
                    }
                }
            }
        }
        print("PASS: growing code, wrapped text and new-block handoffs keep the native caret above the toolbar")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "EditorCaretVisibility", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
