import UIKit
import SwiftUI

@MainActor
final class EditorModel: ObservableObject {
    @Published var title = "First block"
    @Published var blockID = "original"
    @Published var caret = "First block".utf16.count
    var returns = 0
    var pendingCarets: [Int]?
    func moveCaret(_ caret: Int) {
        if pendingCarets != nil {
            pendingCarets?.append(caret)
        } else {
            self.caret = caret
        }
    }
    func enter(_ title: String, _ caret: Int) {
        returns += 1
        self.title = String((title as NSString).substring(from: caret))
        self.caret = 0
        blockID = "new-\(returns)"
    }
}

private struct BulletMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { let view = UIView(); view.tag = 77; return view }
    func updateUIView(_ view: UIView, context: Context) {}
}

private struct EditorHost: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack {
            HStack(alignment: .top, spacing: 2) {
                BulletMarker().frame(width: 24, height: 24)
                OutlinerInlineEditor(text: model.title, blockID: model.blockID,
                    desiredCaretUTF16Offset: model.caret,
                    onTextChange: { model.title = $0; model.caret = $1 },
                    onReturn: model.enter,
                    onBackspace: { _, _ in },
                    onCaretChange: model.moveCaret)
            }
            Spacer()
        }.frame(width: 326)
    }
}

@main
struct ReturnHandoffCheck {
    @MainActor static func main() {
        let model = EditorModel()
        let host = UIHostingController(rootView: EditorHost(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host; window.makeKeyAndVisible()
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.view.layoutIfNeeded() }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func editor() -> UITextView { descendants(host.view).compactMap { $0 as? UITextView }.first! }
        func marker() -> UIView { descendants(host.view).first { $0.tag == 77 }! }
        var failures = 0
        settle()
        func type(_ text: String, in view: UITextView) {
            if view.delegate?.textView?(view, shouldChangeTextIn: view.selectedRange, replacementText: text) ?? true {
                view.insertText(text)
            }
        }
        let original = editor()
        type("\n", in: original)
        settle()
        let next = editor()
        let bulletTop = marker().convert(.zero, to: host.view).y
        let editorTop = next.convert(.zero, to: host.view).y
        let position = next.caretRect(for: next.selectedTextRange!.end)
        if model.returns != 1 || !model.title.isEmpty || next.selectedRange.location != 0 {
            print("FAIL: Enter must hand off to an empty block at offset zero"); failures += 1
        }
        if abs(editorTop - bulletTop) > 0.34 || position.width == 0 {
            print("FAIL: new block editor top=\(editorTop) bullet top=\(bulletTop) caret=\(position)"); failures += 1
        }
        type("Second block", in: next)
        settle()
        let beforeShift = model.returns
        func shiftEnter() {
            let commands = editor().keyCommands ?? []
            if let command = commands.first(where: { ($0.input == "\r" || $0.input == "\n") && $0.modifierFlags == .shift }), let action = command.action {
                if !editor().canPerformAction(action, withSender: command) {
                    print("FAIL: Shift+Enter action is not available to the responder"); failures += 1
                }
                editor().perform(action, with: command)
            } else {
                type("\n", in: editor())
            }
        }
        shiftEnter()
        settle()
        if model.returns != beforeShift || model.title != "Second block\n" {
            print("FAIL: Shift+Enter must insert a newline in the current block; returns=\(model.returns) title=\(model.title.debugDescription)"); failures += 1
        }
        model.title = "😀alpha beta"; model.blockID = "selection"; model.caret = model.title.utf16.count
        settle()
        editor().selectedRange = NSRange(location: 2, length: 5)
        let beforeSelection = model.returns
        shiftEnter()
        settle()
        if model.returns != beforeSelection || model.title != "😀\n beta" || editor().selectedRange.location != 3 {
            print("FAIL: Shift+Enter must replace a UTF-16 selection with a newline"); failures += 1
        }
        model.title = "Before"; model.blockID = "rapid"; model.caret = 6
        settle()
        let beforeRapid = model.returns
        type("\n", in: editor())
        shiftEnter()
        type("After", in: editor())
        settle()
        if model.returns != beforeRapid + 1 || model.title != "\nAfter" || editor().selectedRange.location != 6 {
            print("FAIL: rapid Enter, Shift+Enter, and typing must preserve the new block text"); failures += 1
        }
        model.title = "Matrix parent 20261018"; model.blockID = "delayed-selection"; model.caret = model.title.utf16.count
        settle()
        model.pendingCarets = []
        editor().selectedRange = NSRange(location: 6, length: 0)
        editor().selectedRange = NSRange(location: 0, length: 6)
        let acknowledgements = model.pendingCarets ?? []
        if acknowledgements != [6, 0] {
            print("FAIL: selection must emit both native caret events before model acknowledgement; got=\(acknowledgements)")
            failures += 1
        }
        for caret in acknowledgements {
            model.caret = caret
            settle()
            if editor().selectedRange != NSRange(location: 0, length: 6) {
                print("FAIL: delayed caret acknowledgement=\(caret) erased native selection=\(editor().selectedRange)")
                failures += 1
            }
        }
        guard failures == 0 else { exit(1) }
        print("PASS: Enter handoff, Shift+Enter, and selection across delayed caret acknowledgements")
    }
}
