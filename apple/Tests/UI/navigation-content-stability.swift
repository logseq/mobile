import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@main struct NavigationContentStabilityCheck {
    @MainActor static func main() async throws {
        let rows: [[String: Any]] = (0..<96).map { index in
            ["depth": index % 3, "hasChildren": index % 3 < 2, "isCollapsed": false,
             "block": ["uuid": "row-\(index)", "title": "Row \(index)", "pageId": "journal"]]
        }
        var routes: [String] = []
        func snapshot() throws -> String {
            let destinations: [[String: Any]] = routes.map { uuid in
                ["uuid": uuid, "page": ["uuid": uuid, "title": uuid],
                 "outlinerRows": [["depth": 0, "block": ["uuid": uuid + "-child", "title": "Child", "pageId": uuid]]]]
            }
            let result: [String: Any] = ["selectedGraphId": "demo", "graphName": "Demo", "outlinerRows": rows,
                "nodeRoutes": destinations]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { request in
            if let data = request.params.payload?.data(using: .utf8),
               let effect = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if effect["kind"] as? String == "open-node", let uuid = effect["text"] as? String { routes.append(uuid) }
                if effect["kind"] as? String == "close-node" { _ = routes.popLast() }
            }
            return try! snapshot()
        }))
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func controllers(_ controller: UIViewController) -> [UIViewController] {
            [controller] + controller.children.flatMap(controllers)
        }
        try await Task.sleep(for: .milliseconds(700))
        let firstRow = views(window).first { $0.accessibilityIdentifier == "outliner.block-action.row-0" }!
        var ancestor = firstRow.superview
        while ancestor != nil && !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
        let scroll = ancestor as! UIScrollView
        scroll.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        try await Task.sleep(for: .milliseconds(300))
        let offset = scroll.contentOffset
        var navigation: UINavigationController?
        var failures: [String] = []
        for opening in (0..<24).map({ $0.isMultiple(of: 2) }) {
            if opening { try runtime.applyHostUpdate(kind: "open-node", payload: #""destination""#) }
            else { _ = navigation!.popViewController(animated: true) }
            for _ in 0..<35 {
                try await Task.sleep(for: .milliseconds(16))
                for guide in views(window).compactMap({ $0 as? OutlinerIndentGuideView }) where !guide.isHidden {
                    if let shape = guide.layer as? CAShapeLayer,
                       let presented = shape.presentation(), let path = presented.path,
                       path.boundingBox.height > guide.bounds.height + 1 {
                        failures.append("Guide animates outside its row: \(path.boundingBox.height) > \(guide.bounds.height)")
                    }
                }
            }
            for _ in 0..<70 {
                let stacks = controllers(window.rootViewController!).compactMap { $0 as? UINavigationController }
                let ready = opening ? stacks.contains(where: { $0.viewControllers.count == 2 && $0.transitionCoordinator == nil })
                    : navigation?.viewControllers.count == 1 && navigation?.transitionCoordinator == nil && routes.isEmpty
                if ready { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let navigations = controllers(window.rootViewController!).compactMap { $0 as? UINavigationController }
            if opening { navigation = navigations.first { $0.viewControllers.count == 2 } }
            guard navigation?.viewControllers.count == (opening ? 2 : 1) else {
                LGInteractionDiagnostics.event("test.navigation.fail", "opening=\(opening) routes=\(routes)")
                try await Task.sleep(for: .milliseconds(350))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("navigation-failure.png"))
                throw failure("The test must exercise real native push and pop transitions: \(navigations.map { $0.viewControllers.count })")
            }
            guard opening || (views(window).contains(where: { $0 === scroll }) && scroll.contentOffset == offset) else {
                throw failure("Switching pages changes retained scroll: opening=\(opening), retained=\(views(window).contains(where: { $0 === scroll })), offset=\(scroll.contentOffset), expected=\(offset), insets=\(scroll.adjustedContentInset), content=\(scroll.contentSize), bounds=\(scroll.bounds)")
            }
        }
        func waitForDepth(_ depth: Int, _ message: String) async throws {
            for _ in 0..<150 {
                if navigation?.viewControllers.count == depth && navigation?.transitionCoordinator == nil
                    && routes.count == depth - 1 { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure(message + ": native=\(navigation?.viewControllers.count ?? -1), routes=\(routes)")
        }
        for destination in ["First", "Second"] {
            try runtime.applyHostUpdate(kind: "open-node", payload: "\"" + destination + "\"")
            try await waitForDepth(destination == "First" ? 2 : 3, "Nested pushes must retain native destinations")
        }
        _ = navigation!.popToRootViewController(animated: true)
        try await waitForDepth(1, "A native pop to root must acknowledge every removed route")
        try runtime.applyHostUpdate(kind: "open-node", payload: #""After pop to root""#)
        try await waitForDepth(2, "A fresh destination must open after a multilevel native pop")
        _ = navigation!.popViewController(animated: true)
        try await waitForDepth(1, "The final native pop must synchronize")
        guard views(window).contains(where: { $0 === scroll }) && scroll.contentOffset == offset else {
            throw failure("Multilevel navigation must retain the root scroll identity and offset")
        }
        guard failures.isEmpty else { throw failure(failures.prefix(4).joined(separator: "; ")) }
        print("PASS: repeated page navigation preserves scroll identity and offset, with no guide flash outside rows")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "NavigationStability", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
