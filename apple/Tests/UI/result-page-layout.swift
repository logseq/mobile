import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class LayoutEffects: LGEffectExecuting {
    let type: String
    init(type: String) { self.type = type }
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        guard effect.kind == "load-result-rows" else { return .init(succeeded: true, message: "", output: .discard) }
        let request = try! JSONSerialization.jsonObject(with: Data(effect.text.utf8)) as! [String: Any]
        let offset = request["offset"] as! Int, limit = request["limit"] as! Int
        let view: [String: Any] = ["uuid": "results", "name": "All", "type": type,
            "columns": [["attr": "block/title", "title": "Name"]],
            "rowCount": 1000, "rowOffset": offset, "rowsDeferred": true, "input": "", "revision": 1,
            "rows": (offset..<min(1000, offset + limit)).map { ["block": ["uuid": "object-\($0)", "title": "Object \($0)", "pageId": "owner"]] }]
        let reply: [String: Any] = ["ok": true, "result": ["isQueryPatch": true,
            "resultRows": ["key": request["key"]!, "view": view]]]
        return .init(succeeded: true, message: String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
    }
}

@main struct ResultPageLayoutCheck {
    @MainActor static func main() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "ResultPageLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
        }
        for isTag in [true, false] {
            for type in ["table", "list", "gallery"] {
                for pushed in [false, true] {
                    let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LayoutEffects(type: type))
                    let columns: [[String: Any]] = [["attr": "block/title", "title": "Name"]]
                    var result: [String: Any] = [
                        "selectedGraphId": "result-layout", "graphName": "Layout",
                        "selectedPage": ["uuid": "owner", "title": isTag ? "Bug" : "Assignee"],
                        "selectedPageIsTag": isTag, "selectedPageIsProperty": !isTag, "outlinerRows": [],
                        "resultViews": ["ownerUuid": "owner", "featureType": isTag ? "class-objects" : "property-objects",
                            "views": [["uuid": "results", "name": "All", "type": type, "columns": columns,
                                "rowCount": 1000, "rowOffset": 0, "rowsDeferred": true, "input": "", "revision": 1,
                                "rows": (0..<12).map { ["block": ["uuid": "object-\($0)", "title": "Object \($0)", "pageId": "owner"]] }]]]]
                    if pushed {
                        result["nodeRoutes"] = [["uuid": "owner", "page": result.removeValue(forKey: "selectedPage")!,
                            "isTag": isTag, "isProperty": !isTag, "resultViews": result.removeValue(forKey: "resultViews")!]]
                        result.removeValue(forKey: "selectedPageIsTag")
                        result.removeValue(forKey: "selectedPageIsProperty")
                    }
                    let response: [String: Any] = ["ok": true, "result": result]
                    try runtime.applyCoreResponse(String(decoding: JSONSerialization.data(withJSONObject: response), as: UTF8.self))
                    try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
                    try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
                    if pushed { try runtime.applyHostUpdate(kind: "open-node", payload: "\"owner\"") }
                    let window = UIWindow(windowScene: scene)
                    let container = UIViewController()
                    let host = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
                    window.rootViewController = container
                    container.addChild(host)
                    container.view.addSubview(host.view)
                    host.didMove(toParent: container)
                    window.makeKeyAndVisible()
                    defer { runtime.stop(); window.isHidden = true }
                    host.view.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: 600)
                    try await wait("\(isTag) \(type): the result viewport must appear") {
                        views(host.view).contains { ($0 as? UIScrollView).map { $0.contentSize.height > 10000 } ?? false }
                    }
                    let scroll = views(host.view).compactMap { $0 as? UIScrollView }.first { $0.contentSize.height > 10000 }!
                    let before = scroll.bounds.height
                    host.view.frame.size.height = 780
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    try await wait("\(isTag) \(type): results must consume the additional 180 points of available height (initial \(before), current \(scroll.bounds.height))") {
                        abs(scroll.bounds.height - before - 180) < 3
                    }
                    print("PASS: \(isTag ? "tag" : "property") \(type) \(pushed ? "pushed" : "root") fills remaining page height and follows resizing")
                }
            }
        }
    }
}
