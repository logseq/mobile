import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@main struct NavigationRestorationStabilityCheck {
    @MainActor static func main() async throws {
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func controllers(_ controller: UIViewController) -> [UIViewController] {
            [controller] + controller.children.flatMap(controllers)
        }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<150 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "NavigationRestoration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        for search in [false, true] {
            for restoreBeforeMount in [true, false] {
                var routes: [String] = []
                var query = ""
                var rowCount = 96
                func rows(_ page: String) -> [[String: Any]] {
                    (0..<rowCount).map { index in
                        ["depth": index % 3, "hasChildren": index % 3 < 2,
                         "block": ["uuid": page + "-child-\(index)", "title": "Page content \(index)",
                                   "pageId": page, "journalTitle": "Today", "journalDay": 20261125]]
                    }
                }
                func snapshot() -> String {
                    let result: [String: Any] = [
                        "graphName": "Restoration", "selectedGraphId": "restoration", "isGraphUnlocked": true,
                        "outlinerRows": rows("journal"), "searchQuery": query,
                        "searchResults": [["uuid": "Search target", "title": "Restored result", "isPage": true]],
                        "nodeRoutes": routes.map { uuid -> [String: Any] in
                            ["uuid": uuid, "page": ["uuid": uuid, "title": uuid], "outlinerRows": rows(uuid)]
                        }
                    ]
                    return String(decoding: try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
                }
                let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { request in
                    if let data = request.params.payload?.data(using: .utf8),
                       let effect = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        switch effect["kind"] as? String {
                        case "search-nodes":
                            query = effect["text"] as? String ?? ""
                        case "open-node", "open-search-result":
                            try? await Task.sleep(for: .milliseconds(30))
                            routes.append(effect["text"] as! String)
                        case "close-node": _ = routes.popLast()
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
                    [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? [])
                        .flatMap(descendants)
                }
                func find(_ identifier: String) -> Int? {
                    backend.rootIDs.flatMap(descendants).first {
                        backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
                    }
                }
                func openNode(from row: String, uuid: String) throws {
                    guard let rowID = find("outliner.block." + row),
                          let nativeRow = descendants(rowID).first(where: {
                              backend.extensionModel(id: $0)?.identifier == "outliner-block-row"
                          }) else {
                        throw NSError(domain: "NavigationRestoration", code: 4,
                                      userInfo: [NSLocalizedDescriptionKey: "Missing native row for " + row])
                    }
                    try backend.performExtensionEvent(node: nativeRow, name: "open-node", values: ["uuid": .string(uuid)])
                }
                func restore() throws {
                    let session: [String: Any] = [
                        "graphId": "restoration", "destination": "journals", "assets": [], "composerExpanded": false,
                        "searchOpen": search, "query": search ? "Restored" : "",
                        "appPath": search ? [] : ["First", "Second"], "searchPath": search ? ["Search target"] : [],
                        "selectedPageId": NSNull(), "settingsOpen": false, "recentGraphIds": []
                    ]
                    try runtime.applyHostUpdate(kind: "restore-ui-session", payload: String(decoding:
                        try JSONSerialization.data(withJSONObject: session), as: UTF8.self))
                }
                if restoreBeforeMount { try restore() }
                let window = UIWindow(windowScene: scene)
                window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
                window.makeKeyAndVisible()
                if !restoreBeforeMount {
                    try await Task.sleep(for: .milliseconds(80))
                    try restore()
                }
                defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
                func navigation() -> UINavigationController? {
                    window.rootViewController.flatMap { controllers($0).compactMap { $0 as? UINavigationController }.first }
                }
                await runtime.drainEffectsForTesting()
                try await wait("Session restore must open the journal root without replaying old routes") {
                    navigation()?.viewControllers.count == 1 && find("outliner.block.journal-child-0") != nil && routes.isEmpty
                }
                let retainedNavigation = navigation()!
                if search {
                    let searchID = backend.rootIDs.flatMap(descendants).first {
                        backend.extensionModel(id: $0)?.identifier == "native-search-presentation"
                    }!
                    try backend.performExtensionEvent(node: searchID, name: "present", values: [:])
                    var field: UISearchTextField?
                    try await wait("Native search input must take focus") {
                        field = views(window).compactMap { $0 as? UISearchTextField }
                            .first { $0.isFirstResponder }
                        return field != nil
                    }
                    field?.insertText("Restored")
                    try await wait("Search must show its matching page") {
                        query == "Restored" && find("search.result.Search target") != nil
                    }
                    try backend.performPress(node: find("search.result.Search target")!)
                } else {
                    try openNode(from: "journal-child-0", uuid: "First")
                    try await wait("The first page must hydrate before opening its child") {
                        retainedNavigation.viewControllers.count == 2 && find("outliner.block.First-child-0") != nil
                    }
                    try openNode(from: "First-child-0", uuid: "Second")
                }
                let expectedDepth = search ? 2 : 3
                let target = search ? "Search target" : "Second"
                do {
                    try await wait("The live route must reach native depth and contain real rows") {
                        retainedNavigation.viewControllers.count == expectedDepth &&
                            retainedNavigation.transitionCoordinator == nil &&
                            find("outliner.block." + target + "-child-0") != nil
                    }
                } catch {
                    print("LIVE_ROUTE search=\(search) routes=\(routes) depth=\(retainedNavigation.viewControllers.count) target=\(find("outliner.block." + target + "-child-0") != nil) lastError=\(runtime.lastError ?? "none")")
                    throw error
                }
                let retained = retainedNavigation.topViewController!
                for count in [250, 1, 96, 250, 96] {
                    rowCount = count
                    try runtime.applyCoreResponse(snapshot())
                    try await Task.sleep(for: .milliseconds(90))
                    guard navigation() === retainedNavigation, retainedNavigation.topViewController === retained else {
                        throw NSError(domain: "NavigationRestoration", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Hydrating a live route replaces its native controller"])
                    }
                }
                _ = retainedNavigation.popToRootViewController(animated: true)
                try await wait("Native back must acknowledge every live route") {
                    retainedNavigation.viewControllers.count == 1 &&
                        retainedNavigation.transitionCoordinator == nil && routes.isEmpty
                }
                guard runtime.lastError == nil else { throw NSError(domain: "NavigationRestoration", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: runtime.lastError!]) }
                print("PASS journal relaunch and live navigation search=\(search) beforeMount=\(restoreBeforeMount)")
            }
        }
        print("PASS: journal relaunch, app and search row hydration, and native multilevel back")
    }
}
