import SwiftUI
import UIKit
@testable import Logseq

@MainActor private final class PageChromeSampler: NSObject {
    var frames: () -> [CGRect] = { [] }
    var phase = ""
    var samples: [(String, [CGRect])] = []
    private var link: CADisplayLink?
    func start() {
        link = CADisplayLink(target: self, selector: #selector(sample))
        link?.add(to: .main, forMode: .common)
    }
    @objc private func sample() { samples.append((phase, frames())) }
    func stop() { link?.invalidate(); link = nil }
}

@main struct DuoPageNavigationChromeCheck {
    @MainActor static func main() async throws {
        var routes: [String] = []
        func snapshot() -> String {
            func rows(_ page: String) -> [[String: Any]] {
                (0..<40).map { index in
                    ["depth": 0, "block": ["uuid": "\(page)-row-\(index)", "title": "Content on \(page), row \(index)", "pageId": page]]
                }
            }
            let result: [String: Any] = ["graphName": "Page navigation", "selectedGraphId": "page-navigation",
                "outlinerRows": rows("Journal"), "nodeRoutes": routes.map { page in
                    ["uuid": page, "page": ["uuid": page, "title": page], "outlinerRows": rows(page)] as [String: Any]
                }]
            return String(decoding: try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { request in
            if let data = request.params.payload?.data(using: .utf8),
               let effect = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                switch effect["kind"] as? String {
                case "open-node":
                    try? await Task.sleep(for: .milliseconds(80))
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
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        if ProcessInfo.processInfo.environment["LOGSEQ_DUO_REGULAR_WIDTH"] == "1" {
            window.traitOverrides.horizontalSizeClass = .regular
        }
        let host = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer).preferredColorScheme(.dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<150 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure(message)
        }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        // Read the rendered glass surface in window coordinates. Shared node-frame
        // caches can be cleared by the outgoing page during a native transition.
        func actionFrames() -> [CGRect] {
            guard views(window).filter({ $0.accessibilityIdentifier == "navigation.capture-rail" && !$0.isHidden }).count == 1 else { return [] }
            var frames: [CGRect] = []
            for view in views(window) where view is UIVisualEffectView || String(describing: type(of: view)).contains("Glass") {
                guard view.window === window, !view.isHidden, view.alpha > 0.01 else { continue }
                let rect = view.convert(view.bounds, to: window)
                guard rect.width > 30 && rect.width < 80 && rect.height > 180 && rect.height < 300 else { continue }
                if !frames.contains(where: { abs($0.minX - rect.minX) < 1 && abs($0.minY - rect.minY) < 1 && abs($0.width - rect.width) < 1 && abs($0.height - rect.height) < 1 }) {
                    frames.append(rect)
                }
            }
            return frames
        }
        try await wait("Duo capture rail must mount") { actionFrames().count == 1 && actionFrames()[0].minX > 300 }
        // The expanded drawer adds its own sidebar/detail navigation controllers.
        // Follow the journal's responder chain to the stack that owns its pages.
        try await wait("The journal row must mount") { views(window).contains { $0.accessibilityIdentifier == "outliner.block-action.Journal-row-0" } }
        let row = views(window).first { $0.accessibilityIdentifier == "outliner.block-action.Journal-row-0" }
        var responder: UIResponder? = row
        var pageNavigation: UINavigationController?
        while let current = responder {
            if let controller = current as? UIViewController, let navigation = controller.navigationController {
                pageNavigation = navigation
                break
            }
            responder = current.next
        }
        guard let navigation = pageNavigation else { throw failure("The visible journal must own a native navigation stack") }
        var pageWidth: CGFloat?
        func waitForDepth(_ depth: Int) async throws {
            try await wait("Navigation must settle at depth \(depth)") {
                navigation.viewControllers.count == depth && navigation.transitionCoordinator == nil && routes.count == depth - 1
            }
            try await Task.sleep(for: .milliseconds(100))
            let width = navigation.topViewController!.view.safeAreaLayoutGuide.layoutFrame.width
            if let pageWidth, abs(width - pageWidth) >= 1 {
                throw failure("Page navigation must preserve the content viewport: \(width) vs \(pageWidth)")
            }
            pageWidth = width
        }
        try runtime.applyHostUpdate(kind: "open-node", payload: "\"Query Playground\"")
        try await waitForDepth(2)
        try await Task.sleep(for: .seconds(1))
        let baseline = actionFrames()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("page-navigation-rail.png"))
        guard baseline.count == 1 else { throw failure("The capture rail must remain visible on pushed pages: \(baseline)") }
        let sampler = PageChromeSampler()
        sampler.frames = actionFrames
        sampler.start()
        defer { sampler.stop() }
        for cycle in 0..<4 {
            sampler.phase = "push-\(cycle)"
            try runtime.applyHostUpdate(kind: "open-node", payload: "\"Simple Queries\"")
            try await waitForDepth(3)
            sampler.phase = "pop-\(cycle)"
            _ = navigation.popViewController(animated: true)
            try await waitForDepth(2)
        }
        sampler.phase = "pop-journal"
        _ = navigation.popViewController(animated: true)
        try await waitForDepth(1)
        sampler.stop()
        var maximumX: CGFloat = 0
        var maximumY: CGFloat = 0
        var missing = 0
        for (phase, frames) in sampler.samples {
            guard frames.count == 1 else { missing += 1; continue }
            let shiftX = zip(frames, baseline).map { abs($0.minX - $1.minX) }.max() ?? 0
            let shiftY = zip(frames, baseline).map { abs($0.minY - $1.minY) }.max() ?? 0
            if shiftX > maximumX || shiftY > maximumY { print("CHROME_SHIFT \(phase) x=\(shiftX) y=\(shiftY) frames=\(frames)") }
            maximumX = max(maximumX, shiftX)
            maximumY = max(maximumY, shiftY)
        }
        print("CHROME_SAMPLES count=\(sampler.samples.count) x=\(maximumX) y=\(maximumY) missing=\(missing)")
        guard sampler.samples.count > 30, missing == 0, maximumX < 1, maximumY < 1 else {
            throw failure("Side actions must retain their positions throughout nested page navigation")
        }
        print("PASS: repeated nested page pushes and native back preserve Duo side action positions on every display frame")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "DuoPageNavigationChrome", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
