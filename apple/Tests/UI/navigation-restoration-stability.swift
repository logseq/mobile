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
                var rowCount = 96
                func rows(_ page: String) -> [[String: Any]] {
                    (0..<rowCount).map { index in
                        ["depth": index % 3, "hasChildren": index % 3 < 2,
                         "block": ["uuid": page + "-child-\(index)", "title": "Restored content \(index)", "pageId": page]]
                    }
                }
                func snapshot() -> String {
                    let result: [String: Any] = [
                        "graphName": "Restoration", "selectedGraphId": "restoration", "isGraphUnlocked": true,
                        "outlinerRows": rows("journal"), "searchQuery": "Restored",
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
                        case "open-node", "open-search-node", "open-search-result":
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
                let expectedDepth = search ? 2 : 3
                var retainedNavigation: UINavigationController?
                func navigation() -> UINavigationController? {
                    if let retainedNavigation { return retainedNavigation }
                    let root = search ? window.rootViewController?.presentedViewController : window.rootViewController
                    return root.flatMap { controllers($0).compactMap { $0 as? UINavigationController }
                        .first { $0.viewControllers.count == expectedDepth } }
                }
                do {
                    try await wait("Restored \(search ? "search" : "app") routes must reach their native depth") {
                        navigation()?.viewControllers.count == expectedDepth && navigation()?.transitionCoordinator == nil
                    }
                } catch {
                    print("RESTORE_STATE routes=\(routes) native=\(navigation()?.viewControllers.count ?? -1) error=\(runtime.lastError ?? "none")")
                    throw error
                }
                retainedNavigation = navigation()
                let target = search ? "Search target" : "Second"
                try await wait("The restored top route must contain real lazy rows") {
                    views(navigation()!.topViewController!.view).contains {
                        $0.accessibilityIdentifier == "outliner.block-action." + target + "-child-0"
                    }
                }
                let retained = navigation()!.topViewController!
                for count in [250, 1, 96, 250, 96] {
                    rowCount = count
                    try runtime.applyCoreResponse(snapshot())
                    try await Task.sleep(for: .milliseconds(90))
                    guard navigation()?.topViewController === retained else {
                        throw NSError(domain: "NavigationRestoration", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Hydrating a restored route replaces its native controller"])
                    }
                }
                _ = navigation()!.popToRootViewController(animated: true)
                try await wait("Native back must acknowledge every restored route") {
                    navigation()?.viewControllers.count == 1 && navigation()?.transitionCoordinator == nil && routes.isEmpty
                }
                guard runtime.lastError == nil else { throw NSError(domain: "NavigationRestoration", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: runtime.lastError!]) }
                print("PASS restoration search=\(search) beforeMount=\(restoreBeforeMount)")
            }
        }
        print("PASS: cold and late app/search restoration, lazy-row hydration and native multilevel back")
    }
}
