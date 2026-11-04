import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class PushedEditorEffects: LGEffectExecuting {
    var actions: [String] = []
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        actions.append(effect.kind)
        return LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct PushedBlockEditorCheck {
    @MainActor static func main() async throws {
        var opened = false
        var editing = false
        func snapshot() throws -> String {
            let row: [String: Any] = ["depth": 0, "block": [
                "uuid": "child", "title": "Edit inside the focused block", "pageId": "sample"
            ]]
            var result: [String: Any] = [
                "graphName": "Editor regression", "selectedGraphId": "editor",
                "selectedPage": ["uuid": "sample", "title": "Sample"],
                "outlinerRows": [["depth": 0, "block": ["uuid": "parent", "title": "Focused block", "pageId": "sample"]]],
                "outlinerState": ["selectedBlockIds": []]
            ]
            if opened {
                var state: [String: Any] = ["selectedBlockIds": []]
                if editing {
                    state["editing"] = ["uuid": "child", "title": "Edit inside the focused block", "caretUTF16Offset": 5]
                }
                result["nodeRoutes"] = [[
                    "uuid": "parent", "title": "Focused block",
                    "page": ["uuid": "sample", "title": "Sample"],
                    "outlinerRows": [row], "outlinerState": state
                ]]
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let effects = PushedEditorEffects()
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        backend.frameReportingEnabled = true
        var frames: [Int: CGRect] = [:]
        backend.onFramesReport = { frames = $0 }
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).last {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<150 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "PushedBlockEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        try await wait("The source block must render") { find("outliner.block.parent") != nil }
        let row = descendants(find("outliner.block.parent")!).first {
            backend.extensionModel(id: $0)?.identifier == "outliner-block-row"
        }!
        try backend.performExtensionEvent(node: row, name: "open-node", values: ["uuid": .string("parent")])
        try await wait("Opening the block must request its destination") { effects.actions.contains("open-node") }
        opened = true
        try runtime.applyCoreResponse(snapshot())
        try await wait("The pushed destination must be visible") {
            backend.rootIDs.flatMap(descendants).contains {
                backend.extensionModel(id: $0)?.identifier == "native-navigation-title" && frames[$0] != nil
            }
        }
        editing = true
        try runtime.applyCoreResponse(snapshot())
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        try await wait("The pushed editor must visibly present its action bar") {
            guard find("toolbar.outliner.editor") != nil else { return false }
            return views(window).compactMap { $0 as? OutlinerEditorToolbarGuide.Probe }.filter { toolbar in
                var ancestor: UIView? = toolbar
                while let view = ancestor {
                    if view.isHidden || view.alpha < 0.01 { return false }
                    ancestor = view.superview
                }
                return toolbar.bounds.height > 0 && window.bounds.contains(toolbar.convert(toolbar.bounds, to: window))
            }.count == 1
        }
        try backend.performPress(node: find("button.outliner.editor.hideKeyboard")!)
        editing = false
        try runtime.applyCoreResponse(snapshot())
        try await wait("Dismissing editing must remove the pushed action bar") { find("toolbar.outliner.editor") == nil }
        guard runtime.lastError == nil else {
            throw NSError(domain: "PushedBlockEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: runtime.lastError!])
        }
        print("PASS: pushed block editing visibly presents its action bar and dismisses it with the keyboard")
    }
}
