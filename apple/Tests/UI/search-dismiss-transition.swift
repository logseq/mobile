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
        print("PASS: empty and populated search close promptly, preserve outgoing content, and retain the journal viewport")
    }

    @MainActor static func check(_ initialQuery: String) async throws {
        var query = ""
        func snapshot() -> String {
            let result: [String: Any] = ["graphName": "Work", "selectedGraphId": "work",
                "outlinerRows": (0..<8).map { index in
                    ["depth": 0, "block": ["uuid": "home-\(index)", "title": "Journal body \(index)",
                        "pageId": "journal-\(index / 2)", "journalTitle": "Oct \(31 - index / 2), 2026",
                        "journalDay": 20261031 - index / 2]] as [String: Any]
                },
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
        guard let homeScroll = views(window).compactMap({ $0 as? UIScrollView }).first(where: {
            $0.bounds.height > 200 && $0.contentSize.height > $0.bounds.height
        }) else { throw failure("Missing retained journal scroll view") }
        let homeHeight = homeScroll.bounds.height
        func journalFrame() -> CGRect? {
            views(window).compactMap { $0 as? UILabel }.first { $0.text == "Journal body 2" }
                .map { $0.convert($0.bounds, to: window) }
        }
        guard let homeJournalFrame = journalFrame() else { throw failure("Missing next-journal body") }
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
        guard searchController(root) != nil else {
            throw failure("Missing active native search controller")
        }
        let fieldFrame = field.convert(field.bounds, to: window)
        guard let cancel = views(window).compactMap({ $0 as? UIControl }).first(where: { control in
            let frame = control.convert(control.bounds, to: window)
            guard frame.minX >= fieldFrame.maxX - 1, abs(frame.midY - fieldFrame.midY) < 24,
                  frame.width >= 20, frame.height >= 20, control.isEnabled, !control.isHidden else { return false }
            guard let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) else { return false }
            return hit === control || hit.isDescendant(of: control)
        }) else { throw failure("Missing visible native Cancel control") }
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
        cancel.sendActions(for: cancel.allControlEvents.contains(.primaryActionTriggered) ? .primaryActionTriggered : .touchUpInside)
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
        for _ in 0..<40 {
            _ = isClosed()
            if closedAfter != nil, homeScroll.bounds.height < homeHeight - 1 {
                throw failure("Returning to journals must preserve the full viewport while the outgoing search keyboard dismisses; before=\(homeHeight), during=\(homeScroll.bounds.height)")
            }
            if closedAfter != nil, let frame = journalFrame(), abs(frame.minY - homeJournalFrame.minY) > 2 {
                throw failure("The returned journal layout must not shrink and expand with the outgoing keyboard; before=\(homeJournalFrame.minY), during=\(frame.minY)")
            }
            try await Task.sleep(for: .milliseconds(16))
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
