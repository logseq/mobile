import UIKit
import SwiftUI
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class SearchKeyboardDismissal: NSObject {
    private(set) var completed = false
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(didHide),
            name: UIResponder.keyboardDidHideNotification, object: nil)
    }
    @objc private func didHide(_ notification: Notification) {
        completed = true
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}

@main struct SearchDismissTransitionCheck {
    @MainActor static func main() async throws {
        try await check("")
        try await check("Needle")
        print("PASS: empty and populated search close promptly, preserve outgoing content, and keep the toolbar at the bottom")
    }

    @MainActor static func check(_ initialQuery: String) async throws {
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
        if !initialQuery.isEmpty {
            field.insertText(initialQuery)
            try await wait("Search results must be visible before closing") { find("search.result.found") != nil }
        }
        try await Task.sleep(for: .milliseconds(250))
        guard let root = window.rootViewController else { throw failure("Missing app controller") }
        if let modal = root.presentedViewController, !(modal is UISearchController) {
            throw failure("Search must close in place instead of adding a full-screen modal transition")
        }
        func searchController(_ controller: UIViewController) -> UISearchController? {
            if let search = controller.navigationItem.searchController, search.isActive { return search }
            for child in controller.children {
                if let search = searchController(child) { return search }
            }
            return controller.presentedViewController.flatMap(searchController)
        }
        guard let search = searchController(root), let delegate = search.searchBar.delegate else {
            throw failure("Missing active native search controller")
        }
        let fieldTop = field.convert(field.bounds, to: window).minY
        let keyboard = SearchKeyboardDismissal()
        let closeStart = ProcessInfo.processInfo.systemUptime
        var closedAfter: Double?
        func isClosed() -> Bool {
            let node = backend.rootIDs.flatMap(descendants).first {
                backend.extensionModel(id: $0)?.identifier == "native-search-presentation"
            }
            guard let node, case .bool(false)? = backend.extensionModel(id: node)?.properties["presented"],
                  find("search.result.found") == nil else { return false }
            if closedAfter == nil { closedAfter = ProcessInfo.processInfo.systemUptime - closeStart }
            return true
        }
        delegate.searchBarCancelButtonClicked?(search.searchBar)
        func retainsQuery() -> Bool {
            let node = backend.rootIDs.flatMap(descendants).first {
                backend.extensionModel(id: $0)?.identifier == "native-search-presentation"
            }
            guard let node, case .string(let value)? = backend.extensionModel(id: node)?.properties["query"],
                  value == initialQuery else { return false }
            return initialQuery.isEmpty || find("search.result.found") != nil
        }
        try await Task.sleep(for: .milliseconds(30))
        _ = isClosed()
        guard field.window == nil || retainsQuery() else {
            throw failure("The outgoing results must remain mounted during dismissal")
        }
        for _ in 0..<6 {
            _ = isClosed()
            guard field.window == nil || field.convert(field.bounds, to: window).minY >= fieldTop - 2 else {
                throw failure("The outgoing search toolbar must not jump to the top during dismissal")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await wait("The search session must be cleared after dismissal") {
            isClosed()
        }
        let elapsed = closedAfter!
        print("Cancel search (\(initialQuery.isEmpty ? "empty" : "populated")): \(Int(elapsed * 1000)) ms")
        guard elapsed < 0.2 else {
            throw failure("Search must restore the page within 200 ms without waiting for keyboard dismissal; took \(Int(elapsed * 1000)) ms")
        }
        try await wait("The native keyboard must finish dismissing independently") { keyboard.completed }
        try await wait("Search must release its input") { !field.isFirstResponder }
        guard window.rootViewController === root else { throw failure("Search must retain the app controller") }
        guard runtime.lastError == nil else { throw failure(runtime.lastError!) }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SearchDismissTransition", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
