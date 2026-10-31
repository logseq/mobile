import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

// Sample the native presentation layer every display frame, including keyboard transitions.
@MainActor private final class SearchTopbarSampler: NSObject {
    let navigation: UINavigationController
    let baseline: CGFloat
    let baselineTopInset: CGFloat
    let rootItem: UINavigationItem
    let baselineLeadingCount: Int
    let baselineTrailingCount: Int
    private var displayLink: CADisplayLink?
    private(set) var samples: [CGFloat] = []
    private var topInsets: [CGFloat] = []
    private var missingChromeFrames = 0

    private static func leadingCount(_ item: UINavigationItem) -> Int {
        (item.leftBarButtonItems?.count ?? 0) + item.leadingItemGroups.reduce(0) { $0 + $1.barButtonItems.count }
    }

    private static func trailingCount(_ item: UINavigationItem) -> Int {
        (item.rightBarButtonItems?.count ?? 0) + item.trailingItemGroups.reduce(0) { $0 + $1.barButtonItems.count }
    }

    init(navigation: UINavigationController) {
        self.navigation = navigation
        baseline = navigation.navigationBar.frame.maxY
        baselineTopInset = navigation.topViewController!.view.safeAreaInsets.top
        rootItem = navigation.viewControllers.first!.navigationItem
        baselineLeadingCount = Self.leadingCount(rootItem)
        baselineTrailingCount = Self.trailingCount(rootItem)
        precondition(baselineLeadingCount > 0 && baselineTrailingCount > 0, "The fixture must render both sides of the topbar")
        super.init()
        displayLink = CADisplayLink(target: self, selector: #selector(sample))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func sample() {
        let bar = navigation.navigationBar
        samples.append((bar.layer.presentation()?.frame ?? bar.frame).maxY)
        if Self.leadingCount(rootItem) < baselineLeadingCount || Self.trailingCount(rootItem) < baselineTrailingCount {
            missingChromeFrames += 1
        }
        // A newly pushed controller has no safe area until it joins the window.
        if let host = navigation.topViewController?.viewIfLoaded, host.window != nil {
            topInsets.append(host.safeAreaInsets.top)
        }
    }

    func verify(_ phase: String) throws {
        let maximumShift = samples.map { abs($0 - baseline) }.max() ?? 0
        let insetShift = topInsets.map { abs($0 - baselineTopInset) }.max() ?? 0
        print("TOPBAR \(phase): frames=\(samples.count), bar shift=\(maximumShift)pt, safe area shift=\(insetShift)pt")
        guard samples.count > 5, maximumShift < 1, insetShift < 1, missingChromeFrames == 0 else {
            throw NSError(domain: "SearchTopbar", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Search must retain the navigation bar, its controls and top safe area during \(phase); maximum shift=\(maximumShift)pt, missing chrome frames=\(missingChromeFrames)"])
        }
        samples.removeAll(keepingCapacity: true)
        topInsets.removeAll(keepingCapacity: true)
    }

    func stop() { displayLink?.invalidate(); displayLink = nil }
}

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
        let navigation = controllers(window.rootViewController!).compactMap { $0 as? UINavigationController }.first!
        let sampler = SearchTopbarSampler(navigation: navigation)
        defer { sampler.stop() }
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
        searchField.insertText("S")
        try await wait("A single character must search and render results") {
            query == "S" && find("search.result.result-0") != nil
        }
        searchField.insertText("earch")
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
        guard searchNavigation() === navigation else { throw failure("Search must retain its navigation controller") }
        try await Task.sleep(for: .milliseconds(500))
        try sampler.verify("opening and typing")
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
            try sampler.verify("opening result \(cycle)")
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
            if cycle < 2 { try await Task.sleep(for: .milliseconds(400)) }
            try sampler.verify("returning from result \(cycle)")
            if cycle == 11 {
                try screenshot("search-result-navigation.png")
            }
        }
        // Native Cancel, core-driven dismissal, and reopening must preserve the same inset.
        for coreDismissal in [false, true] {
            let field = views(window).compactMap { $0 as? UISearchTextField }.first { $0.isFirstResponder }!
            let fieldFrame = field.convert(field.bounds, to: window)
            if coreDismissal {
                try backend.performExtensionEvent(node: searchID, name: "dismiss", values: [:])
            } else {
                guard let cancel = views(window).compactMap({ $0 as? UIControl }).first(where: { control in
                    let frame = control.convert(control.bounds, to: window)
                    guard frame.minX >= fieldFrame.maxX - 1, abs(frame.midY - fieldFrame.midY) < 24,
                          frame.width >= 20, frame.height >= 20, control.isEnabled, !control.isHidden else { return false }
                    guard let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) else { return false }
                    return hit === control || hit.isDescendant(of: control)
                }) else { throw failure("Missing native Cancel") }
                cancel.sendActions(for: cancel.allControlEvents.contains(.primaryActionTriggered) ? .primaryActionTriggered : .touchUpInside)
            }
            try await Task.sleep(for: .milliseconds(800))
            try sampler.verify(coreDismissal ? "core dismissal" : "native Cancel")
            try backend.performExtensionEvent(node: searchID, name: "present", values: [:])
            try await wait("Search must reopen with focus") {
                views(window).contains { ($0 as? UISearchTextField)?.isFirstResponder == true }
            }
            try await Task.sleep(for: .milliseconds(500))
            try sampler.verify("reopening")
        }
        guard runtime.lastError == nil else { throw failure(runtime.lastError!) }
        print("PASS: search keeps a stable topbar through opening, page/block results, Back, Cancel, core dismissal, and reopening")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SearchResultNavigation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
