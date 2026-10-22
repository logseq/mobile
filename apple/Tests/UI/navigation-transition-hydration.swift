import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@main struct NavigationTransitionHydrationCheck {
    @MainActor static func main() async throws {
        var routes: [String] = []
        var rowCount = 96
        var revisions = 0
        func rows(_ page: String) -> [[String: Any]] {
            (0..<rowCount).map { index in
                ["depth": index % 3, "hasChildren": index % 3 < 2,
                 "block": ["uuid": page + "-child-\(index)", "title": "Loaded row \(index)", "pageId": page]]
            }
        }
        func snapshot() -> String {
            let result: [String: Any] = [
                "graphName": "Transition hydration", "selectedGraphId": "transition-hydration",
                "outlinerRows": rows("journal"),
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
                case "open-node": routes.append(effect["text"] as! String)
                case "close-node": _ = routes.popLast()
                default: break
                }
            }
            return snapshot()
        }))
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<150 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(16))
            }
            throw NSError(domain: "NavigationTransitionHydration", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        try await Task.sleep(for: .milliseconds(300))
        try await wait("The root outliner must mount") {
            views(window).contains { $0.accessibilityIdentifier == "outliner.block-action.journal-child-0" }
        }
        var responder: UIResponder? = views(window).first {
            $0.accessibilityIdentifier == "outliner.block-action.journal-child-0"
        }
        var containingNavigation: UINavigationController?
        while let current = responder {
            if let controller = current as? UIViewController, let navigation = controller.navigationController {
                containingNavigation = navigation
                break
            }
            responder = current.next
        }
        let navigation = containingNavigation!
        var observedAnimatedPushes = 0
        var observedAnimatedPops = 0
        for cycle in 0..<6 {
            try runtime.applyHostUpdate(kind: "open-node", payload: "\"Destination \(cycle)\"")
            try await wait("A real animated push must start") {
                navigation.viewControllers.count == 2 && navigation.transitionCoordinator != nil
            }
            observedAnimatedPushes += 1
            let retained = navigation.topViewController!
            for count in [0, 256, 1, 96] {
                rowCount = count
                revisions += 1
                try runtime.applyCoreResponse(snapshot())
                try await Task.sleep(for: .milliseconds(24))
            }
            try await wait("Hydration must finish without replacing the incoming controller") {
                navigation.transitionCoordinator == nil && navigation.topViewController === retained
            }
            _ = navigation.popViewController(animated: true)
            guard navigation.transitionCoordinator != nil else {
                throw NSError(domain: "NavigationTransitionHydration", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "The check must exercise animated native pops"])
            }
            observedAnimatedPops += 1
            for count in [256, 0, 96] {
                rowCount = count
                revisions += 1
                try runtime.applyCoreResponse(snapshot())
                try await Task.sleep(for: .milliseconds(24))
            }
            try await wait("Hydration during native back must settle both route owners") {
                navigation.viewControllers.count == 1 && navigation.transitionCoordinator == nil && routes.isEmpty
            }
        }
        guard runtime.lastError == nil else {
            throw NSError(domain: "NavigationTransitionHydration", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: runtime.lastError!])
        }
        print("PASS: \(observedAnimatedPushes) native pushes, \(observedAnimatedPops) native pops and \(revisions) lazy-row replacements during transitions")
    }
}
