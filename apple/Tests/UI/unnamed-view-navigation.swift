import SwiftUI
import UIKit
import LogseqModel
@testable import Logseq
@testable import LUIAppleBackend

@MainActor private final class UnnamedViewEffects: LGEffectExecuting {
    var routes: [[String: Any]] = []

    func snapshot() throws -> String {
        let result: [String: Any] = ["selectedGraphId": "legacy-view", "graphName": "Legacy views",
            "isGraphUnlocked": true, "nodeRoutes": routes, "outlinerRows": []]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
    }

    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        guard effect.kind == "open-node" else { return .init(succeeded: true, message: "", output: .discard) }
        let tag = effect.text == "person"
        var route: [String: Any] = ["uuid": effect.text, "page": ["uuid": effect.text, "title": tag ? "Person" : "Foo"],
            "isTag": tag, "outlinerRows": [], "blocks": []]
        if tag {
            route["resultViews"] = ["ownerUuid": "person", "featureType": "class-objects", "views": [
                ["uuid": "legacy-view", "name": "", "type": "list", "persisted": true,
                 "rows": [], "columns": [], "properties": [], "rowCount": 0, "error": NSNull()]]]
        }
        routes.append(route)
        do { return .init(succeeded: true, message: try snapshot()) }
        catch { return .init(succeeded: false, message: String(describing: error)) }
    }
}

@main struct UnnamedViewNavigationCheck {
    @MainActor static func main() async throws {
        let effects = UnnamedViewEffects()
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(effects.snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true; window.rootViewController = nil }
        let backend = runtime.renderer.backend
        func nodes(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(nodes)
        }
        func allNodes() -> [Int] { backend.rootIDs.flatMap(nodes) }
        func find(_ identifier: String) -> Int? {
            allNodes().last { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier }
        }
        func wait(_ label: String, until predicate: () -> Bool) async throws {
            for _ in 0..<100 {
                let errors = LogseqRuntimeLog.shared.records(errorsOnly: true).map { $0.message }
                if let error = runtime.lastError ?? errors.first { throw failure(error) }
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure(label)
        }
        try runtime.applyHostUpdate(kind: "open-node", payload: "\"person\"")
        try await wait("Person collection must mount") { find("view.select.person") != nil }
        guard let view = find("view.tab.legacy-view"), backend.model(id: view)?.property(.text)?.stringValue == "New view" else {
            throw failure("Unnamed saved views need master's New view menu label")
        }
        try runtime.applyHostUpdate(kind: "open-node", payload: "\"foo\"")
        try await wait("Later navigation must keep working") {
            effects.routes.count == 2 && allNodes().contains {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == "title.node"
                    && backend.model(id: $0)?.property(.text)?.stringValue == "Foo"
            }
        }
        print("PASS: an unnamed saved view opens and later page navigation remains usable")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "UnnamedViewNavigation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
