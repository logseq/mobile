import UIKit
import SwiftUI
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class SearchKeyboardDismissal: NSObject {
    private(set) var completed = false
    private(set) var completedAt: Double?
    private(set) var duration: Double?
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(didHide),
            name: UIResponder.keyboardDidHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willHide),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }
    @objc private func willHide(_ notification: Notification) {
        duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
    }
    @objc private func didHide(_ notification: Notification) {
        completed = true
        completedAt = ProcessInfo.processInfo.systemUptime
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}

@main struct SearchDismissTransitionCheck {
    @MainActor static func main() async throws {
        try await check("")
        try await check("Needle")
        print("PASS: empty and populated search close promptly, retain the native toolbar and search controller, and avoid another query")
    }

    @MainActor static func check(_ initialQuery: String) async throws {
        var query = ""
        var searchRequests = 0
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
               effect["kind"] as? String == "search-nodes" {
                searchRequests += 1
                query = effect["text"] as? String ?? ""
            }
            return snapshot()
        }))
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
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
        func controllers(_ value: UIViewController) -> [UIViewController] {
            [value] + value.children.flatMap(controllers)
        }
        guard let mainNavigation = controllers(window.rootViewController!).compactMap({ $0 as? UINavigationController }).first else {
            throw failure("Missing the main navigation controller")
        }
        guard let composerID = find("surface.composer.root") else { throw failure("Missing composer") }
        try await wait("The floating composer must be laid out") { frames[composerID] != nil }
        let composerBeforeSearch = frames[composerID]!

        if #available(iOS 26.0, *) {
            let outliners = views(window).compactMap { $0 as? UIScrollView }.filter {
                $0.bounds.height > 200 && $0.contentSize.height > $0.bounds.height
            }
            guard !outliners.isEmpty, outliners.allSatisfy({ $0.bottomEdgeEffect.isHidden }) else {
                throw failure("The native outliner must not draw a background wash behind the composer/search controls")
            }
        }
        guard let journal = views(window).compactMap({ $0 as? UILabel }).first(where: { $0.text == "Journal body 2" }) else {
            throw failure("Missing retained journal body")
        }
        guard mainNavigation.topViewController?.navigationItem.searchController == nil else {
            throw failure("Inactive search must not leave a search field or glass surface behind")
        }
        guard let presentation = backend.rootIDs.flatMap(descendants).first(where: {
            backend.extensionModel(id: $0)?.identifier == "native-search-presentation"
        }) else { throw failure("Missing search presentation") }
        try backend.performExtensionEvent(node: presentation, name: "present", values: [:])
        try await wait("Search must accept native input") {
            views(window).contains { ($0 as? UISearchTextField)?.isFirstResponder == true }
        }
        guard let nativeSearch = mainNavigation.topViewController?.navigationItem.searchController else {
            throw failure("Search must belong to the main navigation controller")
        }
        let field = views(window).compactMap { $0 as? UISearchTextField }.first { $0.isFirstResponder }!
        if !initialQuery.isEmpty {
            field.insertText(initialQuery)
            try await wait("Search results must be visible before closing") { find("search.result.found") != nil }
        }
        try await Task.sleep(for: .milliseconds(700))
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
        guard let search = searchController(root),
              let searchNavigation = controllers(root).compactMap({ $0 as? UINavigationController }).first(where: {
                  $0.viewControllers.contains { $0.navigationItem.searchController === search }
              }) else {
            throw failure("Missing active native search controller")
        }
        guard search === nativeSearch else { throw failure("Search must retain the main native controller") }
        let fieldFrame = field.convert(field.bounds, to: window)
        guard let cancel = views(window).compactMap({ $0 as? UIControl }).first(where: { control in
            let frame = control.convert(control.bounds, to: window)
            guard frame.minX >= fieldFrame.maxX - 1, abs(frame.midY - fieldFrame.midY) < 24,
                  frame.width >= 20, frame.height >= 20, control.isEnabled, !control.isHidden else { return false }
            guard let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) else { return false }
            return hit === control || hit.isDescendant(of: control)
        }) else { throw failure("Missing visible native Cancel control") }
        var cleanedUpDuringNativeDismissal = false
        let originalEventHandler = backend.onEvent
        backend.onEvent = { event in
            if case .extension(_, _, "dismiss", _) = event {
                cleanedUpDuringNativeDismissal = search.presentingViewController != nil
            }
            originalEventHandler?(event)
        }
        let requestsBeforeCancel = searchRequests
        let keyboard = SearchKeyboardDismissal()
        let closeStart = ProcessInfo.processInfo.systemUptime
        var nativeControllerClosedAfter: Double?
        cancel.sendActions(for: cancel.allControlEvents.contains(.primaryActionTriggered) ? .primaryActionTriggered : .touchUpInside)
        for _ in 0..<40 {
            if nativeControllerClosedAfter == nil, search.presentingViewController == nil {
                nativeControllerClosedAfter = ProcessInfo.processInfo.systemUptime - closeStart
            }
            guard searchNavigation.view.window === window else {
                throw failure("Cancelling search must let the system controller finish its keyboard transition without tearing down its navigation host")
            }
            guard let composer = frames[composerID], abs(composer.minY - composerBeforeSearch.minY) < 2 else {
                throw failure("The underlying composer must remain at the bottom while the system keyboard closes; initial=\(composerBeforeSearch), current=\(String(describing: frames[composerID]))")
            }
            guard journal.window === window, journal.isDescendant(of: mainNavigation.view) else {
                throw failure("System bar transitions must retain the journal content")
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        try await wait("The native keyboard must finish dismissing independently") { keyboard.completed }
        try await wait("Search must release its input") { !field.isFirstResponder }
        try await wait("The core session must be cleared after native dismissal") {
            guard case .bool(false)? = backend.extensionModel(id: presentation)?.properties["presented"] else { return false }
            return true
        }
        print("Cancel \(initialQuery.isEmpty ? "empty" : "populated"): keyboard ended at \(Int(((keyboard.completedAt ?? closeStart) - closeStart) * 1000)) ms; advertised duration \(Int((keyboard.duration ?? 0) * 1000)) ms; search controller ended at \(Int((nativeControllerClosedAfter ?? 0) * 1000)) ms")
        guard !cleanedUpDuringNativeDismissal else {
            throw failure("Search data cleanup must follow the native dismissal instead of competing with its animation")
        }
        guard searchRequests == requestsBeforeCancel else { throw failure("Closing search must not run another query") }
        guard searchNavigation.view.window === window else { throw failure("The native search host must remain available for reopening") }
        guard window.rootViewController === root else { throw failure("Search must retain the app controller") }
        guard runtime.lastError == nil else { throw failure(runtime.lastError!) }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SearchDismissTransition", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
