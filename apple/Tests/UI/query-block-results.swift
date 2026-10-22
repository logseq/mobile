import SwiftUI
import UIKit
import Vision
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class QueryEffects: LGEffectExecuting {
    var opened: [String] = []
    var actions: [String] = []
    var viewEdits: [[String: Any]] = []
    var saveType: ((String, String) throws -> String)?
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "open-node" { opened.append(effect.text) }
        actions.append(effect.kind)
        if effect.kind == "result-view", let data = effect.text.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            viewEdits.append(payload)
            if payload["action"] as? String == "save",
               let view = payload["viewUuid"] as? String,
               let type = (payload["config"] as? [String: Any])?["type"] as? String,
               let saveType {
                do { return LGEffectResolution(succeeded: true, message: try saveType(view, type)) }
                catch { return LGEffectResolution(succeeded: false, message: String(describing: error)) }
            }
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
        var viewTypes: [String: String] = [:]
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
                    ["attr": "block/title", "title": "Name", "kind": "default", "editable": true, "filterOperators": ["is", "is-not", "text-contains", "text-not-contains"]],
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
                        ["attr": "user.property/Score", "kind": "number", "text": index == 1 ? "" : "\(index + 1)", "editable": true,
                         "raw": ["type": "ref-uuid", "value": String(format: "30000000-0000-4000-8000-%012d", index + 1)]],
                        ["attr": "user.property/Ready", "kind": "checkbox", "text": "true", "editable": true,
                         "raw": ["type": "bool", "value": true]]
                    ]
                    return result
                }
                query["ownerUuid"] = "query-owner"
                query["featureType"] = "query-result"
                query["views"] = ["list", "table", "gallery", "broken"].map { type -> [String: Any] in
                    ["uuid": type, "name": type.capitalized, "type": viewTypes[type] ?? (type == "broken" ? "table" : type),
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
        effects.saveType = { view, type in viewTypes[view] = type; return try snapshot() }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        var nativeFrames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { nativeFrames = $0 }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
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
        func verifyDisclosure(expanded: Bool, screenshot: String) async throws {
            guard let toggle = find("query.toggle.query-owner"),
                  let icon = backend.model(id: toggle)?.property(.icon)?.stringValue else {
                throw failure("Results must expose a disclosure icon")
            }
            let symbol = expanded ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill"
            guard backend.iconSource(for: icon) == .systemName(symbol), UIImage(systemName: symbol) != nil else {
                throw failure("Results must resolve the same native triangle as blocks: \(icon), expanded=\(expanded)")
            }
            try await Task.sleep(for: .milliseconds(250))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(screenshot))
        }
        try await verifyDisclosure(expanded: true, screenshot: "query-disclosure-expanded.png")
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
        try await verifyDisclosure(expanded: false, screenshot: "query-disclosure-collapsed.png")
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
        for attr in ["user.property/Score", "user.property/Ready"] {
            for row in ["header", "result-0", "result-1", "result-2"] {
                guard let divider = find("view.cell.separator.table.\(row).\(attr)"),
                      backend.model(id: divider)?.property(.orientation)?.stringValue == "vertical" else {
                    throw failure("Table columns must have native vertical separators")
                }
                try await wait("Column dividers must have visible native geometry") {
                    nativeFrames[divider].map { $0.width > 0 && $0.width <= 1.1 && $0.height >= 48 } ?? false
                }
                let header = find("view.cell.separator.table.header.\(attr)")!
                if let frame = nativeFrames[divider], let heading = nativeFrames[header], abs(frame.minX - heading.minX) > 0.5 {
                    throw failure("Header and body column dividers must align")
                }
            }
        }
        let tableText = try await capture("query-table.png")
        guard tableText.contains("Name") && tableText.contains("Project result 1") else {
            throw failure("Table cells must have visible native content: \(tableText)")
        }
        try backend.performPress(node: find("view.cell.table.result-0.block/title")!)
        try await wait("Name must open its native text editor") { find("view.edit.value.table") != nil }
        guard find("view.edit.clear.table") == nil else { throw failure("Name must not offer Clear value") }
        try backend.performPress(node: find("view.edit.cancel.table")!)
        try await wait("Name dismissal must finish") { window.rootViewController?.presentedViewController == nil }
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
        window.overrideUserInterfaceStyle = .dark
        try await Task.sleep(for: .milliseconds(150))
        func verifySettingsSheet(_ name: String) async throws {
            _ = try await capture(name)
            guard let presented = window.rootViewController?.presentedViewController else {
                throw failure("Settings must use a native sheet")
            }
            let frame = presented.view.convert(presented.view.bounds, to: window)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let pixel = CGPoint(x: 8, y: frame.minY + 100)
            var rgba = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: -pixel.x, y: pixel.y - window.bounds.height + 1)
            context.draw(image.cgImage!, in: window.bounds)
            guard abs(Int(rgba[0]) - 0) <= 3, abs(Int(rgba[1]) - 45) <= 3, abs(Int(rgba[2]) - 56) <= 3 else {
                throw failure("Dark settings background must match the graph palette; sampled RGBA: \(rgba), frame: \(frame)")
            }
            guard fields(in: presented.view).allSatisfy({ $0.borderStyle == .none }) else {
                throw failure("Grouped settings inputs must use the native row background")
            }
            guard presented.sheetPresentationController?.detents.count == 2,
                  frame.height < window.bounds.height * 0.8 else {
                throw failure("Settings must open as an expandable calendar-like sheet: \(frame)")
            }
        }
        try backend.performPress(node: find("view.filter.table")!)
        try await wait("Native filter settings must present") { find("view.filter.list.table") != nil }
        try backend.performPress(node: find("view.filter.add.table")!)
        try await verifySettingsSheet("query-filter-dark.png")
        let settingsText = try await capture("query-view-settings.png")
        guard settingsText.contains("Filters") && settingsText.contains("Name") && settingsText.contains("Contains") else {
            throw failure("Filter and sort controls must render visibly: \(settingsText)")
        }
        try backend.performPress(node: find("view.settings.cancel.table")!)
        try await wait("Filter dismissal must finish") { window.rootViewController?.presentedViewController == nil }
        try backend.performPress(node: find("view.sort.table")!)
        try await wait("Native sort settings must present") { find("view.sort.list.table") != nil }
        try backend.performPress(node: find("view.sort.add.table")!)
        try await verifySettingsSheet("query-sort-dark.png")
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
        func fields(in view: UIView) -> [UITextField] {
            ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap { fields(in: $0) }
        }
        for (mode, style, dark) in [
            ("system", UIUserInterfaceStyle.light, false), ("system", .dark, true),
            ("light", .dark, false), ("dark", .light, true)
        ] {
            try runtime.applyHostUpdate(kind: "settings", payload: "{\"appearance\":\"\(mode)\",\"language\":\"system\",\"spellCheck\":true,\"autoCorrection\":true,\"sidebarTabs\":[],\"baseURL\":\"https://api.logseq.io\",\"version\":\"test\",\"revision\":\"test\"}")
            window.overrideUserInterfaceStyle = style
            _ = try await capture("query-search-\(mode)-\(style == .dark ? "dark" : "light").png")
            guard let field = fields(in: window.rootViewController!.view).first(where: { $0.placeholder == "Search results" }) else {
                throw failure("Search must display a native input")
            }
            let frame = field.convert(field.bounds, to: window)
            guard frame.minX >= 0, frame.maxX <= window.bounds.maxX - 4 else {
                throw failure("Search must fit its indented collection without expanding the screen: \(frame)")
            }
            guard field.borderStyle == .none else {
                throw failure("An inline search uses one native search surface, without a separate rounded black input")
            }
            for focused in [false, true] {
                if focused { field.becomeFirstResponder() } else { field.resignFirstResponder() }
                try await Task.sleep(for: .milliseconds(200))
                let frame = field.convert(field.bounds, to: window)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let pixel = CGPoint(x: frame.maxX - 12, y: frame.midY)
                var rgba = [UInt8](repeating: 0, count: 4)
                let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.translateBy(x: -pixel.x, y: pixel.y - window.bounds.height + 1)
                context.draw(image.cgImage!, in: window.bounds)
                let expected = dark ? [25, 57, 77] : [248, 248, 248]
                guard zip(rgba.prefix(3), expected).allSatisfy({ abs(Int($0.0) - $0.1) <= 3 }) else {
                    try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("query-search-wrong-color.png"))
                    throw failure("Search must use the theme surface in \(mode)/\(style.rawValue), focused=\(focused): \(rgba), expected \(expected)")
                }
            }
        }
        try runtime.applyHostUpdate(kind: "settings", payload: #"{"appearance":"system","language":"system","spellCheck":true,"autoCorrection":true,"sidebarTabs":[],"baseURL":"https://api.logseq.io","version":"test","revision":"test"}"#)
        try backend.performPress(node: find("view.type.option.gallery.table")!)
        try await wait("The type icon must save the active view's type") {
            effects.viewEdits.contains { ($0["viewUuid"] as? String) == "gallery"
                && ($0["config"] as? [String: Any])?["type"] as? String == "table" }
        }
        try await wait("Changing the current view's type must mount its new renderer") {
            find("view.table.scroll.gallery") != nil && find("view.gallery.gallery") == nil
        }
        try await Task.sleep(for: .milliseconds(250))
        guard let horizontal = views(window).compactMap({ $0 as? UIScrollView }).first(where: {
            $0.window != nil && $0.contentSize.width > $0.bounds.width + 100
        }) else { throw failure("The changed table must remain horizontally scrollable") }
        horizontal.setContentOffset(CGPoint(x: 100, y: 0), animated: false)
        let changedText = try await capture("query-type-changed-table.png")
        guard changedText.contains("Name") && changedText.contains("Score") else {
            throw failure("Changing view type must visibly replace the native gallery: \(changedText)")
        }
        try backend.performPress(node: find("view.type.option.gallery.gallery")!)
        try await wait("Switching back must restore the gallery renderer") { find("view.gallery.gallery") != nil }
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
