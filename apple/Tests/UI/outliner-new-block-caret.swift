import SwiftUI
import UIKit
import LogseqModel
@testable import Logseq
@testable import LUIAppleBackend

@MainActor private final class NewBlockCaretEffects: LGEffectExecuting {
    let journal: Bool
    var completed: [[String: Any]] = []
    var draft = "Start"
    var caret = 5
    var blockID = "block-0"
    var returns = 0

    init(journal: Bool) { self.journal = journal }

    func row(_ uuid: String, _ title: String) -> [String: Any] {
        var block: [String: Any] = ["uuid": uuid, "title": title, "pageId": "page"]
        if journal { block.merge(["journalDay": 20261101, "journalTitle": "Today"]) { _, value in value } }
        return ["depth": 0, "block": block, "hasChildren": false, "isCollapsed": false]
    }

    func snapshot() -> String {
        var result: [String: Any] = ["selectedGraphId": "caret", "graphName": "Caret regression",
            "outlinerRows": completed + [row(blockID, draft)],
            "outlinerState": ["editing": ["uuid": blockID, "title": draft, "caretUTF16Offset": caret]]]
        if !journal { result["selectedPage"] = ["uuid": "page", "title": "Caret regression"] }
        return String(decoding: try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
    }

    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        switch effect.kind {
        case "change-outliner-text": draft = effect.text; caret = effect.value ?? draft.utf16.count
        case "move-outliner-caret": caret = effect.value ?? caret
        case "return-outliner-editor":
            completed.append(row(blockID, effect.text)); returns += 1
            blockID = "block-\(returns)"; draft = ""; caret = 0
        default: return .init(succeeded: true, message: "", output: .discard)
        }
        return .init(succeeded: true, message: snapshot())
    }
}

@main struct OutlinerNewBlockCaretCheck {
    @MainActor static func main() async throws {
        for journal in [true, false] { try await check(journal: journal) }
        print("PASS: new blocks stay above the real editor toolbar in journals and pages")
    }

    @MainActor static func check(journal: Bool) async throws {
        let effects = NewBlockCaretEffects(journal: journal)
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(effects.snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true; window.rootViewController = nil }
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
        func nodes(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(nodes)
        }
        func toolbar() -> CGRect? {
            guard let id = backend.rootIDs.flatMap(nodes).last(where: {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == "toolbar.outliner.editor"
            }) else { return nil }
            return frames[id]
        }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func editor() -> UITextView? {
            views(window).compactMap { $0 as? UITextView }.first { $0.isFirstResponder }
        }
        for _ in 0..<100 {
            if editor() != nil, let bar = toolbar(), bar.width > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let original = editor(), let bar = toolbar(), bar.width > 0 else {
            let ids = backend.rootIDs.flatMap(nodes).compactMap { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue }.filter { $0.contains("toolbar") }
            throw failure("Missing real editor or toolbar: focused=\(editor() != nil) toolbar=\(String(describing: toolbar())) ids=\(ids) frames=\(frames.count) runtime=\(String(describing: runtime.lastError))")
        }
        for index in 1...25 {
            if index == 25 {
                var ancestor = original.superview
                while ancestor != nil && !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
                guard let scroll = ancestor as? UIScrollView else { throw failure("Missing outliner scroll view") }
                let top = -scroll.adjustedContentInset.top
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: top), animated: false)
                try await Task.sleep(for: .milliseconds(180))
                guard abs(scroll.contentOffset.y - top) < 1 else { throw failure("Manual scrolling must not snap back to the caret") }
            }
            guard let field = editor() else { throw failure("New-block handoff lost focus") }
            if field.delegate?.textView?(field, shouldChangeTextIn: field.selectedRange, replacementText: "\n") ?? true {
                field.insertText("\n")
            }
            await runtime.drainEffectsForTesting()
            try await Task.sleep(for: .milliseconds(160))
            window.layoutIfNeeded()
            guard effects.returns == index, let field = editor(), field === original,
                  let selection = field.selectedTextRange, let bar = toolbar() else {
                throw failure("Every Return must retain the native editor and create exactly one block")
            }
            let caret = field.convert(field.caretRect(for: selection.end), to: window)
            if caret.maxY > bar.minY - 7.5 {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("new-block-caret-failure.png"))
                throw failure("New block caret is under the editor toolbar: journal=\(journal) index=\(index) caret=\(caret) toolbar=\(bar)")
            }
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("new-block-caret-\(journal ? "journal" : "page").png"))
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "OutlinerNewBlockCaret", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
