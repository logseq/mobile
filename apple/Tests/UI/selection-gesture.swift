// Interactive companion to nested-selection-toolbar.swift. Launch with the runtime
// check runner's --interactive mode and exercise actual touch long presses.
import SwiftUI
@testable import Logseq

@MainActor private final class SelectionGestureEffects: LGEffectExecuting {
    var routes: [String] = []
    var root = "Journal"
    var selected: String?

    func row(_ uuid: String, _ title: String, page: String) -> [String: Any] {
        ["depth": 0, "block": ["uuid": uuid, "title": title, "pageId": page]]
    }

    func rows(_ page: String) -> [[String: Any]] {
        [row(page + "-child", "Hold here to select on " + page, page: page),
         row(page == "Journal" ? "Page A" : "Linked B", "Open linked page using this bullet", page: page)]
    }

    func snapshot() -> String {
        var result: [String: Any] = [
            "graphName": "Gesture audit", "selectedGraphId": "gesture-audit", "isGraphUnlocked": true,
            "recentPages": [["uuid": "Recent C", "title": "Recent C"]],
            "outlinerRows": rows(root),
            "outlinerState": ["selectedBlockIds": routes.isEmpty ? selected.map { [$0] } ?? [] : []],
            "searchQuery": "Found", "searchResults": [["uuid": "Found", "title": "Found", "isPage": true]],
            "nodeRoutes": routes.map { uuid -> [String: Any] in
                ["uuid": uuid, "page": ["uuid": uuid, "title": uuid], "outlinerRows": rows(uuid),
                 "outlinerState": ["selectedBlockIds": uuid == routes.last ? selected.map { [$0] } ?? [] : []]]
            }
        ]
        if root != "Journal" { result["selectedPage"] = ["uuid": root, "title": root] }
        return String(decoding: try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
    }

    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        switch effect.kind {
        case "open-node", "open-search-result": routes.append(effect.text); selected = nil
        case "close-node": _ = routes.popLast(); selected = nil
        case "select-sidebar-page": root = effect.text; routes = []; selected = nil
        case "long-press-outliner-block": selected = effect.text
        case "outliner-toolbar":
            if effect.text == "copy" || effect.text == "unselect" { selected = nil }
        default: break
        }
        print("GESTURE_AUDIT kind=\(effect.kind) root=\(root) depth=\(routes.count) selection=\(selected ?? "none")")
        return LGEffectResolution(succeeded: true, message: snapshot(), output: .coreResponse)
    }
}

@main struct SelectionGestureApplication: App {
    private let runtime: LGRuntime

    init() {
        let effects = SelectionGestureEffects()
        runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try! runtime.applyCoreResponse(effects.snapshot())
        try! runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try! runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
    }

    var body: some Scene {
        WindowGroup { LGRendererRoot(renderer: runtime.renderer) }
    }
}
