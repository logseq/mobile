import UIKit
import SwiftUI
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class EditorKeyboardProbe: NSObject {
    var top: CGFloat?
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(changed),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
    @objc private func changed(_ note: Notification) {
        top = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue.minY
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}

@main struct SearchEditorToolbarCheck {
    @MainActor static func main() async throws {
        let keyboard = EditorKeyboardProbe()
        var opened = false
        var editing = false
        func snapshot() -> String {
            let state = editing ? #","outlinerState":{"editing":{"uuid":"child","title":"Draft","caretUTF16Offset":5}}"# : ""
            let route = opened ? #","nodeRoutes":[{"uuid":"found","page":{"uuid":"page","title":"Found"},"outlinerRows":[{"depth":0,"block":{"uuid":"child","title":"Draft","pageId":"page"}}]"# + state + "}]" : ""
            return #"{"ok":true,"result":{"graphName":"Work","selectedGraphId":"work","searchQuery":"Draft","searchResults":[{"uuid":"found","title":"Found","isPage":true}]"# + route + "}}"
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { request in
            if let payload = request.params.payload?.data(using: .utf8),
               let effect = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                print("SEARCH_EFFECT \(effect["kind"] ?? "unknown")")
                switch effect["kind"] as? String {
                case "open-search-result", "open-node": opened = true
                case "tap-outliner-block": editing = true
                case "outliner-toolbar": if effect["text"] as? String == "hideKeyboard" { editing = false }
                default: break
                }
            }
            return snapshot()
        }))
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String, in root: Int? = nil) -> Int? {
            (root.map(descendants) ?? backend.rootIDs.flatMap(descendants)).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<60 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw failure(message)
        }
        func press(_ identifier: String) throws {
            guard let id = find(identifier) else { throw failure("Missing " + identifier) }
            try backend.performPress(node: id)
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; runtime.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let searchID = backend.rootIDs.flatMap(descendants).first {
            backend.extensionModel(id: $0)?.identifier == "native-search-presentation"
        }!
        try backend.performExtensionEvent(node: searchID, name: "present", values: [:])
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        try await wait("Native search must become ready for typing") {
            views(window).compactMap { $0 as? UISearchTextField }.contains { $0.isFirstResponder }
        }
        views(window).compactMap { $0 as? UISearchTextField }.first { $0.isFirstResponder }!.insertText("Draft")
        try await wait("The search query must render its result") { find("search.result.found") != nil }
        try press("search.result.found")
        try await wait("Search result must open its outliner") { find("outliner.block.child") != nil }
        try await Task.sleep(for: .milliseconds(500))
        // Use the same native row event as a real tap on block content.
        let row = backend.rootIDs.flatMap(descendants).first {
            backend.extensionModel(id: $0)?.identifier == "outliner-block-row"
        }!
        runtime.renderer.receiveForTesting(LGRendererEvent(kind: .extension, nodeID: row,
            extensionIdentifier: "outliner-block-row", extensionName: "edit",
            extensionValues: ["uuid": .string("child")]))
        try await wait("Editing a search result must mount editor chrome inside search") {
            guard let search = backend.rootIDs.flatMap(descendants).first(where: {
                backend.extensionModel(id: $0)?.identifier == "native-search-presentation"
            }), let children = backend.extensionModel(id: search)?.children, children.count > 2 else { return false }
            return find("toolbar.outliner.editor", in: children[2]) != nil
        }
        let search = backend.rootIDs.flatMap(descendants).first {
            backend.extensionModel(id: $0)?.identifier == "native-search-presentation"
        }!
        let chrome = backend.extensionModel(id: search)!.children[2]
        guard find("toolbar.outliner.editor", in: chrome) != nil else { throw failure("Missing editor toolbar") }
        var measuredFrame: CGRect?
        try await wait("The search editor toolbar must be visible above the keyboard") {
            measuredFrame = views(window).compactMap { $0 as? UIScrollView }.compactMap { scroll in
                let rect = scroll.convert(scroll.bounds, to: window)
                return scroll.window != nil && rect.height >= 42 && rect.height <= 60
                    && rect.minY > window.bounds.height / 2
                    && rect.maxY <= min(window.bounds.maxY, keyboard.top ?? window.bounds.maxY) + 1 ? rect : nil
            }.first
            return measuredFrame != nil
        }
        if let directory = ProcessInfo.processInfo.environment["LOGSEQ_LAYOUT_SCREENSHOTS"] {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("logseq-search-editor.png"))
        }
        guard runtime.lastError == nil else { throw failure(runtime.lastError!) }
        let hide = find("button.outliner.editor.hideKeyboard", in: chrome)!
        try backend.performPress(node: hide)
        try await wait("Hide keyboard must remove the search editor toolbar") {
            find("toolbar.outliner.editor", in: chrome) == nil
        }
        print("PASS: search-result editing presents and dismisses its native editor toolbar; frame=\(String(describing: measuredFrame))")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "SearchEditorToolbar", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
