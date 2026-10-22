import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@main struct NestedSelectionToolbarCheck {
    @MainActor static func main() async throws {
        var routes: [String] = []
        var selectedPage: String?
        var selected = false
        var longPressed: [String] = []
        var performed: [String] = []
        func snapshot() throws -> String {
            let projections: [[String: Any]] = routes.map { uuid in
                ["uuid": uuid, "page": ["uuid": uuid, "title": uuid],
                 "outlinerRows": [["depth": 0, "block": ["uuid": uuid + "-child", "title": "Select this block", "pageId": uuid]]],
                 "outlinerState": ["selectedBlockIds": selected && uuid == routes.last ? [uuid + "-child"] : []]]
            }
            let root = selectedPage ?? "journal"
            var result: [String: Any] = [
                "graphName": "Work", "selectedGraphId": "work", "nodeRoutes": projections,
                "recentPages": [["uuid": "Recent C", "title": "Recent C"]],
                "outlinerRows": [["depth": 0, "block": ["uuid": root + "-child", "title": "Select this block", "pageId": root]]],
                "outlinerState": ["selectedBlockIds": selected && routes.isEmpty ? [root + "-child"] : []],
                "searchQuery": "Found", "searchResults": [["uuid": "Found", "title": "Found", "isPage": true]]
            ]
            if let selectedPage { result["selectedPage"] = ["uuid": selectedPage, "title": selectedPage] }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { request in
            if let data = request.params.payload?.data(using: .utf8),
               let effect = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                switch effect["kind"] as? String {
                case "open-node", "open-search-result":
                    if let uuid = effect["text"] as? String { routes.append(uuid); selected = false }
                case "close-node": _ = routes.popLast(); selected = false
                case "select-sidebar-page":
                    selectedPage = effect["text"] as? String; routes = []; selected = false
                case "long-press-outliner-block":
                    if let uuid = effect["text"] as? String { longPressed.append(uuid); selected = true }
                case "outliner-toolbar":
                    if let action = effect["text"] as? String {
                        performed.append(action)
                        if action == "copy" || action == "unselect" { selected = false }
                    }
                default: break
                }
            }
            return try! snapshot()
        }))
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; runtime.stop() }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func descendants(_ id: Int) -> [Int] {
            let backend = runtime.renderer.backend
            return [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            let backend = runtime.renderer.backend
            return backend.rootIDs.flatMap(descendants).last {
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
        try await Task.sleep(for: .milliseconds(500))
        for destination in ["Page A", "Page B", "Recent C", "Linked D", "Found"] {
            if destination == "Found" {
                guard let search = find("button.search") else { throw failure("Missing search action") }
                try runtime.renderer.backend.performPress(node: search)
                try await wait("Native search must accept input") {
                    views(window).contains { ($0 as? UISearchTextField)?.isFirstResponder == true }
                }
                views(window).compactMap { $0 as? UISearchTextField }.first { $0.isFirstResponder }!.insertText("Found")
                try await wait("Search must show its result") { find("search.result.Found") != nil }
                try runtime.renderer.backend.performPress(node: find("search.result.Found")!)
            } else if destination == "Recent C" {
                let backend = runtime.renderer.backend
                func navigationControllers(_ controller: UIViewController) -> [UINavigationController] {
                    (controller as? UINavigationController).map { [$0] } ?? controller.children.flatMap(navigationControllers)
                }
                guard let navigation = navigationControllers(window.rootViewController!).first(where: { $0.viewControllers.count > 1 }) else {
                    throw failure("Linked pages must have a native navigation stack")
                }
                _ = navigation.popToRootViewController(animated: true)
                try await wait("Return to the root before opening Recent") { routes.isEmpty && navigation.transitionCoordinator == nil }
                guard let drawer = backend.rootIDs.flatMap(descendants).first(where: { backend.model(id: $0)?.kind == .drawer }) else {
                    throw failure("Missing sidebar drawer")
                }
                try backend.performToggle(node: drawer, checked: true)
                try await wait("Recent must expose its page") { find("link.sidebar.page.Recent C") != nil }
                try backend.performPress(node: find("link.sidebar.page.Recent C")!)
                try await wait("Recent selects the root page instead of pushing") { selectedPage == "Recent C" && routes.isEmpty }
            } else {
                try runtime.applyHostUpdate(kind: "open-node", payload: String(decoding: try JSONSerialization.data(withJSONObject: destination, options: .fragmentsAllowed), as: UTF8.self))
            }
            try await Task.sleep(for: .milliseconds(650))
            let backend = runtime.renderer.backend
            guard let row = backend.rootIDs.flatMap(descendants).first(where: {
                guard let node = backend.extensionModel(id: $0), node.identifier == "outliner-block-row",
                      case let .string(payload) = node.properties["payload"] else { return false }
                return payload.contains(destination + "-child")
            }) else { throw failure("Missing destination row") }
            func longPress() throws {
                try backend.performExtensionEvent(node: row, name: "long-press", values: ["uuid": .string(destination + "-child")])
            }
            try longPress()
            try await wait("The native long press must traverse the core effect boundary") { longPressed.last == destination + "-child" }
            try await wait("The active destination owns selection actions") { find("button.outliner.selection.copy") != nil }
            try await Task.sleep(for: .milliseconds(650))
            let nativeActions = views(window).compactMap { $0 as? UIScrollView }.filter {
                let rect = $0.convert($0.bounds, to: window)
                return $0.window != nil && rect.height >= 44 && rect.height <= 60
                    && rect.minY > window.bounds.height - 130
            }
            guard !nativeActions.isEmpty else { throw failure("Long press must show the native selection bar on " + destination) }
            try backend.performPress(node: find("button.outliner.selection.copy")!)
            try await wait("Copy must use the shared toolbar pipeline") { performed.last == "copy" }
            try await wait("Copy clears the destination's selection") { find("toolbar.outliner.selection") == nil }
            try longPress()
            try await wait("Selection must reopen after copying") { find("button.outliner.selection.unselect") != nil }
            try backend.performPress(node: find("button.outliner.selection.unselect")!)
            try await wait("Unselect must reach the active destination") { performed.last == "unselect" }
            try await wait("Unselect removes native selection chrome") { find("toolbar.outliner.selection") == nil }
        }
        print("PASS: direct, linked/nested, search, Recent root and links from Recent display native selection actions and dispatch Copy/Unselect")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "NestedSelection", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
