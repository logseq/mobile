import SwiftUI
import UIKit
import Vision
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class QueryEffects: LGEffectExecuting {
    var opened: [String] = []
    var actions: [String] = []
    var viewEdits: [[String: Any]] = []
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "open-node" { opened.append(effect.text) }
        actions.append(effect.kind)
        if effect.kind == "result-view", let data = effect.text.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            viewEdits.append(payload)
        }
        return LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct QueryBlockResultsCheck {
    @MainActor static func main() async throws {
        var resultCount = 3
        var queryError: String?
        var selected: [String] = []
        var includeViews = false
        func snapshot() throws -> String {
            let results: [[String: Any]] = (0..<resultCount).map { index in
                ["block": ["uuid": "result-\(index)", "title": "Project result \(index + 1)",
                           "pageId": "page",
                           "breadcrumbs": [["uuid": "page", "title": "Workspace"]],
                           "children": index == 0 ? [["uuid": "child", "title": "Nested child", "pageId": "page"]] : [],
                           "markup": [
                            ["type": "emphasis", "style": "bold", "children": [["type": "text", "text": "Project"]]],
                            ["type": "text", "text": " result \(index + 1)"]]]]
            }
            var query: [String: Any] = ["kind": "simple", "source": "#Project", "rows": results,
                                        "error": queryError as Any? ?? NSNull()]
            if includeViews {
                let columns: [[String: Any]] = [
                    ["attr": "block/title", "title": "Name", "kind": "string", "editable": true],
                    ["attr": "user.property/Score", "title": "Score", "kind": "number", "editable": true, "ref": true,
                     "filterValues": (1...3).map { value in
                        ["title": "\(value)", "match": [String(format: "30000000-0000-4000-8000-%012d", value)]]
                     }],
                    ["attr": "user.property/Ready", "title": "Ready", "kind": "checkbox", "editable": true]
                ]
                let rows = results.enumerated().map { index, result -> [String: Any] in
                    var result = result
                    result["properties"] = [
                        ["attr": "block/title", "text": "Project result \(index + 1)", "editable": true,
                         "raw": ["type": "string", "value": "Project result \(index + 1)"]],
                        ["attr": "user.property/Score", "kind": "number", "text": "\(index + 1)", "editable": true,
                         "raw": ["type": "ref-uuid", "value": String(format: "30000000-0000-4000-8000-%012d", index + 1)]],
                        ["attr": "user.property/Ready", "kind": "checkbox", "text": "true", "editable": true,
                         "raw": ["type": "bool", "value": true]]
                    ]
                    return result
                }
                query["ownerUuid"] = "query-owner"
                query["featureType"] = "query-result"
                query["views"] = ["list", "table", "gallery", "broken"].map { type -> [String: Any] in
                    ["uuid": type, "name": type.capitalized, "type": type == "broken" ? "table" : type,
                     "columns": columns, "rows": type == "broken" ? [] : rows,
                     "error": type == "broken" ? "Invalid view configuration" : NSNull()]
                }
            }
            let result: [String: Any] = [
                "graphName": "Query rendering", "selectedGraphId": "query-check",
                "outlinerState": ["selectedBlockIds": selected],
                "outlinerRows": [["depth": 0, "hasChildren": false, "isCollapsed": false,
                                  "block": ["uuid": "query-owner", "title": "Project overview", "pageId": "page",
                                            "query": query]]]
            ]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let effects = QueryEffects()
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func nativeRow(_ uuid: String) -> Int? {
            guard let block = find("outliner.block.\(uuid)") else { return nil }
            return descendants(block).first { backend.extensionModel(id: $0)?.identifier == "outliner-block-row" }
        }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure(message + "; runtime error: " + (runtime.lastError ?? "none"))
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        try await wait("Query results must mount in the native outline") {
            find("query.result.query-owner.2") != nil
        }
        try await Task.sleep(for: .milliseconds(700))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("query-block-results.png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
        let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        guard visible.contains("Project result 1") && visible.contains("Project result 3") else {
            throw failure("Query results must have visible rich-text content: \(visible)")
        }
        guard visible.contains("Workspace"), find("outliner.block.child") == nil else {
            throw failure("List results need breadcrumbs and initially folded children")
        }
        try backend.performExtensionEvent(node: nativeRow("result-0")!, name: "collapse", values: ["uuid": .string("result-0")])
        try await wait("Expanding a result must render its child block") { find("outliner.block.child") != nil }
        try backend.performExtensionEvent(node: nativeRow("result-0")!, name: "collapse", values: ["uuid": .string("result-0")])
        try await wait("Result children must fold independently") { find("outliner.block.child") == nil }
        try backend.performExtensionEvent(node: nativeRow("result-0")!, name: "long-press", values: ["uuid": .string("result-0")])
        try await Task.sleep(for: .milliseconds(150))
        selected = ["result-0"]
        try runtime.applyCoreResponse(snapshot())
        try await wait("Selected results must display the select bar") { find("toolbar.outliner.selection") != nil }
        try await Task.sleep(for: .milliseconds(350))
        let selectedImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try selectedImage.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("query-selection.png"))
        try backend.performPress(node: find("button.outliner.selection.copy")!)
        try await wait("Select bar actions must reach the outliner pipeline") { effects.actions.contains("outliner-toolbar") }
        selected = []
        try runtime.applyCoreResponse(snapshot())
        try backend.performPress(node: find("query.toggle.query-owner")!)
        try await wait("Folding must unmount query rows") { find("query.rows.query-owner") == nil }
        try backend.performPress(node: find("query.toggle.query-owner")!)
        try await wait("Unfolding must restore query rows") { find("query.result.query-owner.0") != nil }
        try backend.performExtensionEvent(node: nativeRow("result-0")!, name: "open-node", values: ["uuid": .string("result-0")])
        try await wait("Pressing a result must request its destination") { effects.opened == ["result-0"] }
        resultCount = 25
        try runtime.applyCoreResponse(snapshot())
        try await wait("Long query results must expose Show more") { find("query.more.query-owner") != nil }
        guard find("query.result.query-owner.24") == nil else { throw failure("Initial result mounting must stay bounded") }
        try backend.performPress(node: find("query.more.query-owner")!)
        try await wait("Show more must expose later results") { find("query.result.query-owner.24") != nil }
        resultCount = 0
        try runtime.applyCoreResponse(snapshot())
        try await wait("Empty query results must be explicit") { find("query.empty.query-owner") != nil }
        queryError = "Invalid query definition"
        try runtime.applyCoreResponse(snapshot())
        try await wait("Query errors must stay inside their block") { find("query.error.query-owner") != nil }
        includeViews = true
        resultCount = 3
        queryError = nil
        try runtime.applyCoreResponse(snapshot())
        try await wait("Multiple saved views must mount") { find("view.tab.table") != nil }
        func capture(_ name: String) async throws -> String {
            try await Task.sleep(for: .milliseconds(350))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(name))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
        _ = try await capture("query-multiple-list.png")
        try backend.performPress(node: find("view.tab.table")!)
        try await wait("Table must mount a horizontal scroll container") { find("view.table.scroll.table") != nil }
        let tableText = try await capture("query-table.png")
        guard tableText.contains("Name") && tableText.contains("Project result 1") else {
            throw failure("Table cells must have visible native content: \(tableText)")
        }
        try backend.performPress(node: find("view.cell.table.result-0.user.property/Score")!)
        try await wait("Table cell editor must present") { find("view.edit.value.table") != nil }
        _ = try await capture("query-cell-editor.png")
        try backend.performTextChange(node: find("view.edit.value.table")!, text: "35")
        try await wait("An open property must offer explicit creation") { find("view.edit.create.table") != nil }
        try backend.performPress(node: find("view.edit.create.table")!)
        try await wait("Typed edits must reach the core action adapter") {
            effects.viewEdits.contains { ($0["action"] as? String) == "editCell" && ($0["value"] as? String) == "35" }
        }
        try await wait("Successful edits dismiss the editor") { find("view.edit.value.table") == nil }
        try await wait("Native dismissal must finish before presenting settings") {
            window.rootViewController?.presentedViewController == nil
        }
        try backend.performPress(node: find("view.filter.table")!)
        try await wait("Native filter settings must present") { find("view.filter.list.table") != nil }
        try backend.performPress(node: find("view.filter.add.table")!)
        let settingsText = try await capture("query-view-settings.png")
        guard settingsText.contains("Filters") && settingsText.contains("Add filter") else {
            throw failure("Filter and sort controls must render visibly: \(settingsText)")
        }
        try backend.performPress(node: find("view.settings.cancel.table")!)
        try await wait("Filter dismissal must finish") { window.rootViewController?.presentedViewController == nil }
        try backend.performPress(node: find("view.sort.table")!)
        try await wait("Native sort settings must present") { find("view.sort.list.table") != nil }
        try backend.performPress(node: find("view.sort.add.table")!)
        let sortText = try await capture("query-sort-settings.png")
        guard sortText.contains("Sort") && sortText.contains("Ascending") else {
            throw failure("Sort controls must visibly render: \(sortText)")
        }
        try backend.performPress(node: find("view.settings.cancel.table")!)
        try await wait("Sort dismissal must finish") { window.rootViewController?.presentedViewController == nil }
        try backend.performPress(node: find("view.tab.gallery")!)
        try await wait("Gallery cards must mount") { find("view.card.gallery.result-0") != nil }
        let galleryText = try await capture("query-gallery.png")
        guard galleryText.contains("Project result 1") else { throw failure("Gallery content must be visible: \(galleryText)") }
        try backend.performPress(node: find("view.search.toggle.query-owner")!)
        try await wait("Search expands from its toolbar icon") { find("view.search.query-owner") != nil }
        try backend.performTextChange(node: find("view.search.query-owner")!, text: "result 1")
        try await wait("Search must filter gallery cards") { find("view.card.gallery.result-1") == nil }
        try backend.performPress(node: find("view.tab.broken")!)
        try await wait("A corrupt view must have a local error") { find("view.error.broken") != nil }
        try backend.performPress(node: find("view.tab.list")!)
        try await wait("Healthy sibling views remain usable") { find("outliner.block.result-0") != nil }
        guard runtime.lastError == nil else { throw failure(runtime.lastError!) }
        print("PASS: block lists, selection, saved view tabs, horizontal tables, typed cell editor, filter/sort settings, gallery, search, and local errors")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "QueryBlockResults", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
