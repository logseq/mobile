import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class JournalRowTrace: NSObject {
    private let readY: () -> CGFloat?
    private var link: CADisplayLink?
    private(set) var samples: [CGFloat] = []

    init(readY: @escaping () -> CGFloat?) {
        self.readY = readY
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(sample))
        self.link = link
        link.add(to: .main, forMode: .common)
        sample()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func sample() {
        if let y = readY() { samples.append(y) }
    }
}

@MainActor private final class JournalKeyboardEffects: LGEffectExecuting {
    var editing: String?
    let imagePath: String

    init(imagePath: String) { self.imagePath = imagePath }

    func snapshot() throws -> String {
        let sections = ["overdue", "doing", "planned"]
        var agenda: [String: Any] = ["graphId": "demo", "page": "day-0", "day": 20261124,
                                     "enabled": true, "success": true]
        for section in sections {
            let block = ["uuid": "task-\(section)", "title": "Task \(section)", "pageId": "source"]
            agenda[section] = [["uuid": "task-\(section)", "block": block]]
        }
        let rows: [[String: Any]] = (0..<96).map { index in
            let day = index / 8
            var block: [String: Any] = ["uuid": "row-\(index)", "title": "Row \(index)", "pageId": "day-\(day)",
                                         "journalDay": 20261124 - day, "journalTitle": "Journal \(day)"]
            if index % 8 == 3 {
                block["title"] = "Image \(index).png"
                block["isAsset"] = true
                block["assetType"] = "image/png"
                block["localPath"] = imagePath
            }
            return ["depth": 0, "block": block]
        }
        let state = editing.map { id in
            ["editing": ["uuid": id, "title": "Row \(id.dropFirst(4))", "caretUTF16Offset": 0]]
        } ?? [:]
        let result: [String: Any] = ["selectedGraphId": "demo", "graphName": "Journals", "outlinerRows": rows,
                                     "journalTasks": agenda, "outlinerState": state]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
    }

    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "editor-outliner-event",
           let payload = try? JSONSerialization.jsonObject(with: Data(effect.text.utf8)) as? [String: Any] {
            editing = payload["uuid"] as? String
        } else if effect.kind == "outliner-toolbar", effect.text == "hideKeyboard" {
            editing = nil
        } else {
            return .init(succeeded: true, message: "", output: .discard)
        }
        return .init(succeeded: true, message: try! snapshot())
    }
}

@main struct JournalKeyboardCheck {
    @MainActor static func main() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        try checkUnmaterializedAnchor(in: scene)
        let imageURL = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 130)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 180, height: 130))
        }
        try image.pngData()!.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let effects = JournalKeyboardEffects(imagePath: imageURL.path)
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(effects.snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true; window.rootViewController = nil }

        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        let prefix = "outliner.block-action."
        func frame(_ view: UIView) -> CGRect { view.convert(view.bounds, to: window) }
        func editor() -> UITextView? { views(window).compactMap { $0 as? UITextView }.first(where: \.isFirstResponder) }
        func label(_ id: String) -> UILabel? {
            views(window).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == prefix + id }
        }
        func wait(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }
        let backend = runtime.renderer.backend
        func nodes(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(nodes)
        }
        func node(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(nodes).first { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier }
        }
        func pinnedIndex() -> Int? {
            guard let id = node("outliner.window"),
                  let attributes = backend.model(id: id)?.property(.dataAttrs)?.stringValue else { return nil }
            let key = "data-pinned-index\u{1f}"
            return attributes.components(separatedBy: "\u{1e}")
                .first(where: { $0.hasPrefix(key) }).flatMap { Int($0.dropFirst(key.count)) }
        }
        try await wait(750)
        func enclosingScroll(_ view: UIView) -> UIScrollView? {
            var ancestor = view.superview
            while let candidate = ancestor {
                if let scroll = candidate as? UIScrollView, scroll.isScrollEnabled { return scroll }
                ancestor = candidate.superview
            }
            return nil
        }
        func currentList() -> UIScrollView? {
            views(window).compactMap { $0 as? UILabel }.first {
                $0.accessibilityIdentifier?.hasPrefix(prefix + "row-") == true &&
                    frame($0).intersects(window.bounds)
            }.flatMap(enclosingScroll)
        }
        guard let initial = currentList() else { throw failure("Missing journals scroll view") }
        let regularInset = initial.adjustedContentInset.bottom
        func end(_ scroll: UIScrollView) -> CGFloat {
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        }
        func trace(_ id: String, action: () throws -> Void) async throws -> [CGFloat] {
            let trace = JournalRowTrace {
                (editor() ?? label(id)).map { frame($0).minY }
            }
            trace.start()
            defer { trace.stop() }
            try action()
            try await wait(950)
            return trace.samples
        }
        var lastEditedBlock: String?
        for fraction: Double? in [0.51, 1.0, nil, 0.76, 1.0] {
            if let fraction {
                for _ in 0..<4 {
                    guard let scroll = currentList() else { throw failure("Missing active journals scroll view") }
                    scroll.setContentOffset(CGPoint(x: 0, y: end(scroll) * fraction), animated: false)
                    try await wait(230)
                }
            }
            guard let scroll = currentList() else { throw failure("Missing active journals scroll view") }
            let desired = window.bounds.maxY - (fraction == 1 ? 160 : 140)
            let visible = views(scroll).compactMap { $0 as? UILabel }.filter {
                $0.accessibilityIdentifier?.hasPrefix(prefix + "row-") == true && (260..<window.bounds.maxY - 110).contains(frame($0).minY)
            }
            let target = fraction == nil
                ? lastEditedBlock.flatMap(label)
                : visible.min(by: { abs(frame($0).minY - desired) < abs(frame($1).minY - desired) })
            guard let target,
                  let targetID = target.accessibilityIdentifier.map({ String($0.dropFirst(prefix.count)) }) else {
                throw failure("No visible block for keyboard test")
            }
            lastEditedBlock = targetID
            let initialY = frame(target).minY
            var ancestor = target.superview
            while ancestor != nil && !(ancestor is OutlinerTextRowView) { ancestor = ancestor?.superview }
            guard let row = ancestor as? OutlinerTextRowView else { throw failure("Missing native row") }
            let opening = try await trace(targetID) {
                row.activateTitle(at: CGPoint(x: 20, y: target.bounds.midY))
            }
            guard let field = editor(), let selection = field.selectedTextRange,
                  effects.editing == targetID, let dismiss = node("button.outliner.editor.hideKeyboard"),
                  let scroll = enclosingScroll(field),
                  let toolbar = views(window).compactMap({ $0 as? OutlinerEditorToolbarGuide.Probe }).first else {
                throw failure("Missing editor or toolbar for \(targetID)")
            }
            let keyboardInset = scroll.adjustedContentInset.bottom
            guard keyboardInset > regularInset + 100 else {
                throw failure("This check needs a docked software keyboard (insets \(regularInset) → \(keyboardInset), offset \(scroll.contentOffset), row \(targetID))")
            }
            let openY = frame(field).minY
            let caret = field.convert(field.caretRect(for: selection.end), to: window)
            let keyboardTop = scroll.convert(scroll.bounds, to: window).maxY - keyboardInset
            let visibleBottom = min(frame(toolbar).minY, keyboardTop)
            let positioned = fraction == nil
                ? abs(openY - initialY) <= 6 && caret.maxY < visibleBottom
                : (2...14).contains(visibleBottom - caret.maxY)
            guard positioned, opening.allSatisfy({ $0 >= openY - 6 }) else {
                throw failure("Opening the keyboard over-scrolled or obscured \(targetID): caret=\(caret) visibleBottom=\(visibleBottom) y=\(opening)")
            }
            guard let editorIndex = pinnedIndex(), editorIndex >= 0 else { throw failure("The editor must be pinned") }
            let closing = try await trace(targetID) { try backend.performPress(node: dismiss) }
            guard editor() == nil, let closed = label(targetID), pinnedIndex() == editorIndex else {
                throw failure("The edited block must keep its virtual slot when closing the keyboard")
            }
            let drift = abs(frame(closed).minY - openY)
            let transient = closing.map { abs($0 - openY) }.max() ?? .infinity
            guard drift <= 1, transient <= 6 else {
                throw failure("Closing the keyboard moved \(targetID) by \(drift)pt, with up to \(transient)pt across frames")
            }
        }
        print("PASS: journal assets and task sections preserve editor position across keyboard changes")
    }

    @MainActor private static func checkUnmaterializedAnchor(in scene: UIWindowScene) throws {
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset.bottom = 280
        scroll.contentSize = CGSize(width: 390, height: 4000)
        controller.view.addSubview(scroll)
        let editor = UITextView(frame: CGRect(x: 0, y: 1400, width: 390, height: 28))
        editor.accessibilityIdentifier = "field.outliner.block.anchor"
        scroll.addSubview(editor)
        scroll.contentOffset.y = 1200

        let retention = OutlinerScrollRetention()
        defer { retention.cancelRestoration() }
        var keyboardDismissed = false
        retention.preserve(scroll, editor: editor, bottomSafeArea: 34) { keyboardDismissed }
        editor.removeFromSuperview()
        scroll.contentOffset.y = 2000
        keyboardDismissed = true
        scroll.contentInset.bottom = 34
        guard abs(scroll.contentOffset.y - 2000) < 1 else {
            throw failure("A transient virtual window without the captured row must not restore its stale offset")
        }

        let title = UILabel(frame: CGRect(x: 0, y: 2100, width: 390, height: 28))
        title.accessibilityIdentifier = "outliner.block-action.anchor"
        scroll.addSubview(title)
        scroll.contentSize.height += 10
        guard abs(scroll.contentOffset.y - 1900) < 1 else {
            throw failure("The remounted row must return to its captured screen position")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "JournalKeyboard", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
