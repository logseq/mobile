import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class RenameEffects: LGEffectExecuting {
    var reject = true
    var requests: [[String: Any]] = []
    var save: ((String) throws -> String)?
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        guard effect.kind == "node-property", let data = effect.text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return LGEffectResolution(succeeded: true, message: "", output: .discard)
        }
        requests.append(payload)
        if reject { return LGEffectResolution(succeeded: false, message: "Storage unavailable") }
        do { return LGEffectResolution(succeeded: true, message: try save?(payload["value"] as? String ?? "") ?? "") }
        catch { return LGEffectResolution(succeeded: false, message: String(describing: error)) }
    }
}

@main struct PageRenameCheck {
    @MainActor static func main() async throws {
        var title = "Original page"
        var graph = "rename-check"
        var canRename = true
        func snapshot() throws -> String {
            let property: [String: Any] = ["attr": "block/title", "title": "Name", "kind": "string",
                "text": title, "editable": true, "raw": ["type": "string", "value": title]]
            let result: [String: Any] = ["selectedGraphId": graph, "graphName": graph,
                "selectedPage": ["uuid": "page", "title": title], "outlinerRows": [],
                "nodeProperties": ["ownerUuid": "page", "properties": [], "rename": canRename ? property as Any : NSNull()]]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let effects = RenameEffects()
        effects.save = { title = $0; return try snapshot() }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        func ids(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(ids)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(ids).first { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier }
        }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw NSError(domain: "PageRename", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer).tint(LogseqThemePolicy.accent))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        func capture(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(300))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(name))
        }
        let editor = "page.rename.page"
        try await wait("Ordinary pages offer Rename page") { find("button.page.rename") != nil }
        try backend.performPress(node: find("button.page.rename")!)
        try await wait("Rename presents a native sheet") { window.rootViewController?.presentedViewController != nil && find("view.edit.value." + editor) != nil }
        try await capture("page-rename-editor.png")
        guard find("view.edit.clear." + editor) == nil else { throw NSError(domain: "PageRename", code: 2) }
        try backend.performTextChange(node: find("view.edit.value." + editor)!, text: "Renamed page")
        try backend.performPress(node: find("view.edit.save." + editor)!)
        try await wait("A failed save keeps the edited name available for retry") {
            effects.requests.count == 1 && find("view.edit.value." + editor) != nil && runtime.lastError == "Storage unavailable"
        }
        try await capture("page-rename-failure.png")
        effects.reject = false
        try await Task.sleep(for: .milliseconds(200))
        try backend.performPress(node: find("view.edit.save." + editor)!)
        try await wait("Successful rename updates the page title and dismisses the editor") {
            title == "Renamed page" && find("view.edit.value." + editor) == nil
                && backend.model(id: find("title.selected-page") ?? -1)?.property(.text)?.stringValue == title
        }
        guard effects.requests.allSatisfy({ $0["graphId"] as? String == "rename-check" && $0["attr"] as? String == "block/title" }) else {
            throw NSError(domain: "PageRename", code: 3)
        }
        try await wait("Native dismissal finishes") { window.rootViewController?.presentedViewController == nil }
        try await capture("page-renamed.png")
        canRename = false
        try runtime.applyCoreResponse(snapshot())
        try await wait("Protected pages do not expose Rename page") { find("button.page.rename") == nil }
        canRename = true
        try runtime.applyCoreResponse(snapshot())
        try await wait("Returning to an ordinary page restores Rename page") { find("button.page.rename") != nil }
        try backend.performPress(node: find("button.page.rename")!)
        try await wait("Rename can be opened again") { find("view.edit.value." + editor) != nil }
        graph = "different-graph"
        try runtime.applyCoreResponse(snapshot())
        try await wait("Changing graphs dismisses the captured rename editor") { find("view.edit.value." + editor) == nil }
        print("PASS: native rename sheet, source text, no Clear value, save failure/retry, title refresh, protected menus and graph isolation")
    }
}
