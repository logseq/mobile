import SwiftUI
import UIKit
import LogseqModel
@testable import Logseq
@testable import LUIAppleBackend

@MainActor private final class TapVisibilityEffects: LGEffectExecuting {
    let journal: Bool
    var editing: String?
    var caret = 0
    init(journal: Bool) { self.journal = journal }

    func snapshot() -> String {
        let rows: [[String: Any]] = (1...30).map { index in
            var block: [String: Any] = ["uuid": "row-\(index)", "title": index == 1 ? "Line 1" + String(repeating: "\nContext", count: 8) : "Line \(index)", "pageId": "page"]
            if journal { block.merge(["journalDay": 20261101, "journalTitle": "Today"]) { _, value in value } }
            return ["depth": 0, "block": block, "hasChildren": false, "isCollapsed": false]
        }
        var result: [String: Any] = ["selectedGraphId": "tap", "graphName": "Tap regression", "outlinerRows": rows]
        if let editing {
            result["outlinerState"] = ["editing": ["uuid": editing, "title": "Line \(editing.dropFirst(4))", "caretUTF16Offset": caret]]
        } else { result["outlinerState"] = ["selectedBlockIds": []] }
        if !journal { result["selectedPage"] = ["uuid": "page", "title": "Tap regression"] }
        return String(decoding: try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
    }

    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        guard effect.kind == "editor-outliner-event" else { return .init(succeeded: true, message: "", output: .discard) }
        let payload = try! JSONSerialization.jsonObject(with: Data(effect.text.utf8)) as! [String: Any]
        editing = payload["uuid"] as? String ?? payload["blockId"] as? String
        caret = payload["caretUTF16Offset"] as? Int ?? 0
        return .init(succeeded: true, message: snapshot())
    }
}

@main struct OutlinerTapCaretVisibilityCheck {
    @MainActor static func main() async throws {
        for journal in [true, false] { try await check(journal: journal) }
        print("PASS: tapping existing blocks reveals the caret above keyboard and toolbar in journals and pages")
    }

    @MainActor static func check(journal: Bool) async throws {
        let effects = TapVisibilityEffects(journal: journal)
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
        func label(_ index: Int) -> UILabel? {
            views(window).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "outliner.block-action.row-\(index)" }
        }
        func editor() -> UITextView? {
            views(window).compactMap { $0 as? UITextView }.first { $0.isFirstResponder }
        }
        try await Task.sleep(for: .milliseconds(700))
        guard let first = label(11) else { throw failure("Missing line 11") }
        var ancestor = first.superview
        while ancestor != nil && !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
        guard let scroll = ancestor as? UIScrollView else { throw failure("Missing outliner scroll view") }
        for (index, keyboardOpen) in [(11, false), (15, true), (18, false)] {
            if !keyboardOpen, effects.editing != nil {
                effects.editing = nil
                try runtime.applyCoreResponse(effects.snapshot())
                window.endEditing(true)
                try await Task.sleep(for: .milliseconds(600))
            }
            // Place an existing row near the bottom, or just above the floating toolbar.
            let desiredY = keyboardOpen ? (toolbar()!.minY - 12) : window.bounds.maxY - 130
            // Materialize the row first, then align its real native label.
            guard let target = label(index) else { throw failure("Missing target line \(index)") }
            let delta = target.convert(target.bounds, to: window).midY - desiredY
            scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top, scroll.contentOffset.y + delta)), animated: false)
            try await Task.sleep(for: .milliseconds(150))
            guard let target = label(index) else { throw failure("Target vanished") }
            var row: UIView? = target
            while row != nil && !(row is OutlinerTextRowView) { row = row?.superview }
            guard let row = row as? OutlinerTextRowView else { throw failure("Missing native row") }
            row.activateTitle(at: CGPoint(x: 20, y: target.bounds.midY))
            await runtime.drainEffectsForTesting()
            try await Task.sleep(for: .milliseconds(900))
            window.layoutIfNeeded()
            guard effects.editing == "row-\(index)", let field = editor(),
                  let selection = field.selectedTextRange, let bar = toolbar() else {
                throw failure("Tap must focus line \(index): editing=\(String(describing: effects.editing))")
            }
            let caret = field.convert(field.caretRect(for: selection.end), to: window)
            let visible = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: window)
            if caret.maxY > min(bar.minY, visible.maxY) - 7.5 || caret.minY < visible.minY {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("tap-caret-failure.png"))
                throw failure("Tapped caret is obscured: journal=\(journal) line=\(index) keyboardOpen=\(keyboardOpen) caret=\(caret) toolbar=\(bar) viewport=\(visible)")
            }
            // Reading elsewhere must remain possible without snapping back to the editor.
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            try await Task.sleep(for: .milliseconds(180))
            guard abs(scroll.contentOffset.y + scroll.adjustedContentInset.top) < 1 else { throw failure("Manual scroll snapped back") }
        }
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "OutlinerTapCaretVisibility", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
