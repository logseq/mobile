import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@main struct SearchResultNavigationCheck {
    @MainActor static func main() async throws {
        func phase(_ name: String) {
            let line = "SEARCH_PHASE \(ProcessInfo.processInfo.systemUptime) \(name)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        phase("start")
        var routes: [String] = []
        var query = ""
        let hits: [[String: Any]] = (0..<80).map { index in
            ["uuid": "result-\(index)", "title": "Search result \(index)",
             "isPage": index < 40]
        }
        func snapshot() -> String {
            let nodes: [[String: Any]] = routes.map { uuid in
                let revealsBlock = uuid == "result-40"
                let pageID = revealsBlock ? "containing-page" : uuid
                let rows: [[String: Any]] = (0..<250).map { index in
                    ["depth": index % 4,
                     "block": ["uuid": revealsBlock && index == 200 ? uuid : "\(uuid)-child-\(index)",
                               "title": "Search result content \(index)", "pageId": pageID]]
                }
                var node: [String: Any] = [
                    "uuid": pageID, "page": ["uuid": pageID, "title": "Opened \(uuid)"],
                    "outlinerRows": rows,
                ]
                if revealsBlock { node["scrollTarget"] = uuid }
                return node
            }
            let result: [String: Any] = [
                "graphName": "Navigation regression", "selectedGraphId": "navigation",
                "searchQuery": query, "searchResults": hits, "nodeRoutes": nodes,
            ]
            return String(decoding: try! JSONSerialization.data(withJSONObject:
                ["ok": true, "result": result]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(),
            effectExecutor: LGCoreEffectExecutor(callCore: { request in
                if let payload = request.params.payload?.data(using: .utf8),
                   let effect = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                    switch effect["kind"] as? String {
                    case "search-nodes": query = effect["text"] as? String ?? ""
                    case "open-search-result", "open-search-node":
                        // The pending route and its asynchronous content arrive separately.
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
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure(message)
        }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func controllers(_ controller: UIViewController) -> [UIViewController] {
            [controller] + controller.children.flatMap(controllers)
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer {
            phase("teardown.begin")
            window.isHidden = true
            window.rootViewController = nil
            runtime.stop()
            phase("teardown.end")
        }
        try await Task.sleep(for: .milliseconds(250))
        let searchID = backend.rootIDs.flatMap(descendants).first {
            backend.extensionModel(id: $0)?.identifier == "native-search-presentation"
        }!
        try backend.performExtensionEvent(node: searchID, name: "present", values: [:])
        try await wait("Native search must accept input") {
            views(window).contains { ($0 as? UISearchTextField)?.isFirstResponder == true }
        }
        let searchField = views(window).compactMap { $0 as? UISearchTextField }
            .first { $0.isFirstResponder }!
        phase("search.presented")
        searchField.insertText("Search")
        try await wait("Search must return page and block results") {
            query == "Search" && find("search.result.result-0") != nil && find("search.result.result-40") != nil
        }
        try await Task.sleep(for: .milliseconds(200))
        let root = window.rootViewController!
        func searchNavigation() -> UINavigationController? {
            controllers(root).compactMap { $0 as? UINavigationController }.first
        }
        try await wait("Search must reuse the main navigation controller") {
            searchNavigation() != nil
        }
        let navigation = searchNavigation()!
        func screenshot(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(name))
        }
        phase("search.results")
        for cycle in 0..<12 {
            let uuid = "result-\(cycle.isMultiple(of: 2) ? 0 : 40)"
            phase("push.request.\(cycle)")
            try backend.performPress(node: find("search.result.\(uuid)")!)
            try await wait("Result must push a visible destination") {
                navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil
            }
            let target = cycle.isMultiple(of: 2) ? "\(uuid)-child-0" : uuid
            try await wait("Result content must mount at its page or revealed block") {
                find("outliner.block.\(target)") != nil
            }
            guard window.rootViewController === root, searchNavigation() === navigation,
                  find("outliner.block.\(target)") != nil else {
                throw failure("Opening a result must retain the search session and its loaded content")
            }
            phase("push.ready.\(cycle)")
            try await wait("Search result pages must retain their native overflow menu") {
                guard let item = navigation.topViewController?.navigationItem else { return false }
                let hasNativeItems = !(item.rightBarButtonItems ?? []).isEmpty
                    || item.trailingItemGroups.contains { !$0.barButtonItems.isEmpty }
                return !navigation.isNavigationBarHidden && hasNativeItems && find("button.connection") != nil
            }
            window.layoutIfNeeded()
            if cycle == 11 { try screenshot("search-result-destination.png") }
            phase("pop.request.\(cycle)")
            _ = navigation.popViewController(animated: true)
            try await wait("Back must restore the result list and settle the native route") {
                navigation.viewControllers.count == 1 && navigation.transitionCoordinator == nil && routes.isEmpty
            }
            try await wait("Back must reactivate search input") {
                views(window).contains { ($0 as? UISearchTextField)?.isFirstResponder == true }
            }
            phase("pop.ready.\(cycle)")
            if cycle == 11 {
                try screenshot("search-result-navigation.png")
            }
        }
        guard runtime.lastError == nil else { throw failure(runtime.lastError!) }
        print("PASS: 12 page/block result pushes and native back transitions preserve search and lazy content")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SearchResultNavigation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
