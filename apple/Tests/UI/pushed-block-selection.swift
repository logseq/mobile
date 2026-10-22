import SwiftUI
import UIKit
import Vision
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class SelectionEffects: LGEffectExecuting {
    var actions: [String] = []
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        actions.append(effect.kind)
        return LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct PushedBlockSelectionCheck {
    @MainActor static func main() async throws {
        var opened = false
        var selected = false
        func snapshot() throws -> String {
            let row: [String: Any] = ["depth": 0, "block": [
                "uuid": "project", "title": "Research nested tags and boolean query composition",
                "pageId": "sample", "breadcrumbs": [["uuid": "sample", "title": "Sample Data"]]
            ]]
            var result: [String: Any] = [
                "graphName": "Selection regression", "selectedGraphId": "selection",
                "outlinerRows": [row], "outlinerState": ["selectedBlockIds": []]
            ]
            if opened {
                result["nodeRoutes"] = [[
                    "uuid": "project", "title": "Research nested tags",
                    "page": ["uuid": "sample", "title": "Sample Data"],
                    "breadcrumbs": [["uuid": "sample", "title": "Sample Data"]],
                    "outlinerRows": [row],
                    "outlinerState": ["selectedBlockIds": selected ? ["project"] : []]
                ]]
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let effects = SelectionEffects()
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).last {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func row() -> Int? {
            guard let block = find("outliner.block.project") else { return nil }
            return descendants(block).first { backend.extensionModel(id: $0)?.identifier == "outliner-block-row" }
        }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure(message)
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        try await wait("The source block must render") { row() != nil }
        try backend.performExtensionEvent(node: row()!, name: "open-node", values: ["uuid": .string("project")])
        try await wait("Opening the block must dispatch navigation") { effects.actions.contains("open-node") }
        opened = true
        try runtime.applyCoreResponse(snapshot())
        try await Task.sleep(for: .milliseconds(500))
        try backend.performExtensionEvent(node: row()!, name: "long-press", values: ["uuid": .string("project")])
        selected = true
        try runtime.applyCoreResponse(snapshot())
        try await wait("A selected pushed block must own a select bar") { find("toolbar.outliner.selection") != nil }
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("pushed-block-selection.png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 0.25)
        try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
        let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        guard visible.contains("Copy") && visible.contains("Delete") && visible.contains("Unselect") else {
            throw failure("The pushed destination must visibly render native bottom actions: \(visible)")
        }
        try backend.performPress(node: find("button.outliner.selection.copy")!)
        try await wait("Copy must reach the shared outliner pipeline") { effects.actions.contains("outliner-toolbar") }
        try backend.performPress(node: find("button.outliner.selection.unselect")!)
        selected = false
        try runtime.applyCoreResponse(snapshot())
        try await wait("Unselect must remove the destination select bar") { find("toolbar.outliner.selection") == nil }
        guard runtime.lastError == nil else { throw failure(runtime.lastError!) }
        print("PASS: pushed block selection visibly presents native actions, dispatches Copy, and dismisses on Unselect")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "PushedBlockSelection", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
