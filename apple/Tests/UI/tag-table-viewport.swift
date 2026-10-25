import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class TableEffects: LGEffectExecuting {
    var columns: [[String: Any]] = []
    var requestedOffsets: [Int] = []
    func view(offset: Int, limit: Int) -> [String: Any] {
        ["uuid": "table", "name": "All", "type": "table", "columns": columns, "properties": columns,
         "rowCount": 1000, "rowOffset": offset, "rowsDeferred": true, "input": "", "revision": 1,
         "rows": (offset..<min(1000, offset + limit)).map {
            ["block": ["uuid": "object-\($0)", "title": "Object \($0)", "pageId": "owner"]]
         }]
    }
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        guard effect.kind == "load-result-rows" else { return .init(succeeded: true, message: "", output: .discard) }
        let request = try! JSONSerialization.jsonObject(with: Data(effect.text.utf8)) as! [String: Any]
        let offset = request["offset"] as! Int, limit = request["limit"] as! Int
        guard limit <= 64 else { fatalError("Viewport reads must stay bounded") }
        requestedOffsets.append(offset)
        let response: [String: Any] = ["ok": true, "result": ["isQueryPatch": true,
            "resultRows": ["key": request["key"]!, "view": view(offset: offset, limit: limit)]]]
        return .init(succeeded: true, message: String(decoding: try! JSONSerialization.data(withJSONObject: response), as: UTF8.self))
    }
}

@main struct TagTableViewportCheck {
    @MainActor static func main() async throws {
        let effects = TableEffects()
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        let columns: [[String: Any]] = [["attr": "block/title", "title": "Name"]] + (0..<24).map {
            ["attr": "user.property/Column\($0)", "title": "Column \($0)"]
        }
        effects.columns = columns
        let response: [String: Any] = ["ok": true, "result": [
            "selectedGraphId": "tag-table", "graphName": "Tag table",
            "selectedPage": ["uuid": "owner", "title": "Bug"], "selectedPageIsTag": true,
            "outlinerRows": [], "nodeProperties": ["ownerUuid": "owner", "classSchema": true, "canAdd": false,
                "schemaProperties": [["attr": "user.property/Notes", "title": "Notes"]]],
            "resultViews": ["ownerUuid": "owner", "featureType": "class-objects", "views": [effects.view(offset: 0, limit: 12)]]]]
        try runtime.applyCoreResponse(String(decoding: JSONSerialization.data(withJSONObject: response), as: UTF8.self))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier }
        }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "TagTableViewport", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true }
        let first = "view.cell.table.object-0.block/title"
        let last = "view.cell.table.object-0.user.property/Column23"
        try await wait("The first cell must appear") { find(first) != nil }
        guard find(last) == nil else { fatalError("Offscreen columns must own no native views") }
        try await wait("The horizontal table viewport must lay out") {
            views(window).contains { ($0 as? UIScrollView).map { $0.contentSize.width > 4000 } ?? false }
        }
        let scroll = views(window).compactMap { $0 as? UIScrollView }.first { $0.contentSize.width > 4000 }!
        scroll.setContentOffset(.init(x: scroll.contentSize.width - scroll.bounds.width, y: 0), animated: false)
        try await wait("Horizontal scrolling must mount the final cells and evict the first") { find(last) != nil && find(first) == nil }
        try await wait("The vertical viewport must retain the complete scroll extent") {
            views(window).contains { ($0 as? UIScrollView).map { $0.contentSize.height > 10000 } ?? false }
        }
        let vertical = views(window).compactMap { $0 as? UIScrollView }.first { $0.contentSize.height > 10000 }!
        vertical.setContentOffset(.init(x: 0, y: vertical.contentSize.height - vertical.bounds.height), animated: false)
        try await wait("Vertical scrolling must request and render the final row") {
            find("view.cell.table.object-999.user.property/Column23") != nil && effects.requestedOffsets.contains { $0 > 900 }
        }
        try backend.performPress(node: find("button.page.tag-properties")!)
        try await wait("The topbar menu must remain responsive") {
            find("property.schema.owner.user.property/Notes") != nil && window.rootViewController?.presentedViewController != nil
        }
        print("PASS: large tag tables load visible row windows, mount visible columns and preserve topbar menu actions")
    }
}
