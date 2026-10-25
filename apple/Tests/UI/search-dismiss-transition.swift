import UIKit
import SwiftUI
@testable import LUIAppleBackend
@testable import Logseq

@main struct SearchDismissTransitionCheck {
    @MainActor static func main() async throws {
        var query = ""
        func snapshot() -> String {
            let result: [String: Any] = ["graphName": "Work", "selectedGraphId": "work",
                "searchQuery": query, "searchResults": query.isEmpty ? [] : [
                    ["uuid": "found", "title": "Needle result", "isPage": true]]]
            return String(decoding: try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { request in
            if let data = request.params.payload?.data(using: .utf8),
               let effect = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               effect["kind"] as? String == "search-nodes" { query = effect["text"] as? String ?? "" }
            return snapshot()
        }))
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure(message)
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; runtime.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try backend.performPress(node: find("button.search")!)
        try await wait("Search must accept native input") {
            views(window).contains { ($0 as? UISearchTextField)?.isFirstResponder == true }
        }
        let field = views(window).compactMap { $0 as? UISearchTextField }.first { $0.isFirstResponder }!
        field.insertText("Needle")
        try await wait("Search results must be visible before closing") { find("search.result.found") != nil }
        try await Task.sleep(for: .milliseconds(250))
        guard let presented = window.rootViewController?.presentedViewController else { throw failure("Missing search presentation") }
        func searchController(_ controller: UIViewController) -> UISearchController? {
            if let search = controller.navigationItem.searchController, search.isActive { return search }
            for child in controller.children {
                if let search = searchController(child) { return search }
            }
            return controller.presentedViewController.flatMap(searchController)
        }
        guard let search = searchController(presented), let delegate = search.searchBar.delegate else {
            throw failure("Missing active native search controller")
        }
        delegate.searchBarCancelButtonClicked?(search.searchBar)
        func retainsQuery() -> Bool {
            let node = backend.rootIDs.flatMap(descendants).first {
                backend.extensionModel(id: $0)?.identifier == "native-search-presentation"
            }
            guard let node, case .string("Needle")? = backend.extensionModel(id: node)?.properties["query"] else { return false }
            return find("search.result.found") != nil
        }
        var animated = false
        for _ in 0..<100 {
            guard retainsQuery() else {
                throw failure("Closing search must preserve the outgoing query and results until dismissal starts")
            }
            if presented.isBeingDismissed || presented.transitionCoordinator != nil {
                animated = true
                break
            }
            guard window.rootViewController?.presentedViewController != nil else {
                throw failure("Search disappeared without a dismissal animation")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard animated else { throw failure("Closing search must start its dismissal animation") }
        try await Task.sleep(for: .milliseconds(30))
        guard retainsQuery() else {
            throw failure("The outgoing results must remain mounted during dismissal")
        }
        try await wait("Search must finish dismissing") { window.rootViewController?.presentedViewController == nil }
        try await wait("The search session must be cleared after dismissal") { find("search.result.found") == nil }
        guard runtime.lastError == nil else { throw failure(runtime.lastError!) }
        print("PASS: native search dismisses with its query and results intact, then clears the closed session")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "SearchDismissTransition", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
