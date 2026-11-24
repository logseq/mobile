import UIKit
import SwiftUI
import Vision
@testable import LUIAppleBackend
@testable import Logseq

@main struct ScrollingNavigationTitleCheck {
    @MainActor static func main() async throws {
        for delayedLoad in [true, false] {
            try await check(delayedLoad: delayedLoad)
        }
        print("PASS: the page title restores after native search with text and images scrolling under the bar in light and Solarized dark")
    }

    @MainActor static func check(delayedLoad: Bool) async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let title = "Project page"
        let appearance = delayedLoad ? "solarized-dark" : "light"
        let imageURL = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let fixture = UIGraphicsImageRenderer(size: CGSize(width: 220, height: 200)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 220, height: 200))
        }
        guard let fixtureData = fixture.pngData() else { throw failure("Could not create the image fixture") }
        try fixtureData.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let rows: [[String: Any]] = (0..<60).map { index in
            var block: [String: Any] = ["uuid": "row-\(index)", "title": "Body row \(index)", "pageId": "page"]
            if index == 6 {
                block["title"] = "Image.png"
                block["isAsset"] = true
                block["assetType"] = "image/png"
                block["localPath"] = imageURL.path
            }
            return ["block": block, "depth": 0]
        }
        func encodeSnapshot(rows: [[String: Any]]) throws -> String {
            let result: [String: Any] = ["graphName": "Work", "selectedGraphId": "work", "outlinerRows": rows,
                "selectedPage": ["uuid": "page", "title": title],
                "outlinerState": ["selectedBlockIds": []]]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let snapshot = try encodeSnapshot(rows: rows)
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { _ in snapshot }))
        if !delayedLoad { try runtime.applyCoreResponse(snapshot) }
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "settings", payload: #"{"appearance":"system","darkTheme":"solarized","language":"en","spellCheck":true,"autoCorrection":true,"sidebarTabs":[],"baseURL":"https://api.logseq.io","version":"test","revision":"test"}"#)
        if !delayedLoad { try runtime.applyHostUpdate(kind: "graph-loading", payload: "false") }
        var observed: String?
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer)
            .environment(\.logseqDarkTheme, .solarized)
            .preferredColorScheme(delayedLoad ? .dark : .light)
            .onPreferenceChange(LUIScrollTitlePreferenceKey.self) { observed = $0 }
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        if delayedLoad {
            try await Task.sleep(for: .milliseconds(350))
            try runtime.applyCoreResponse(#"{"ok":true,"result":{"graphName":"Work","selectedGraphId":"work","outlinerRows":[]}}"#)
            try await Task.sleep(for: .milliseconds(200))
            try runtime.applyCoreResponse(snapshot)
            try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        }
        try await Task.sleep(for: .milliseconds(1000))
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        guard let scroll = scrollViews(window).first(where: {
            guard $0.contentSize.height > $0.bounds.height + 300, $0.bounds.height > 200 else { return false }
            let center = $0.convert(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: window)
            var hit = window.hitTest(center, with: nil)
            while let view = hit {
                if view === $0 { return true }
                hit = view.superview
            }
            return false
        }) else { throw failure("Missing native outliner scroll view") }
        if observed != nil {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("title-initial-failure.png"))
            throw failure("The contextual toolbar title must stay hidden while its content heading is visible")
        }
        let top = -scroll.adjustedContentInset.top
        scroll.setContentOffset(CGPoint(x: 0, y: top + 180), animated: false)
        try await Task.sleep(for: .milliseconds(700))
        guard observed == title else { throw failure("The title must appear after its heading crosses the viewport top") }
        var updatedRows = rows
        updatedRows[3] = ["block": ["uuid": "replacement", "title": "Replacement row", "pageId": "page"], "depth": 0]
        try runtime.applyCoreResponse(encodeSnapshot(rows: updatedRows))
        try await Task.sleep(for: .milliseconds(700))
        guard observed == title else { throw failure("Replacing a visible page row must keep the contextual title") }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func capture(_ phase: String) throws -> (CGImage, CGRect) {
            guard let bar = views(window).compactMap({ $0 as? UINavigationBar }).first(where: {
                let frame = $0.convert($0.bounds, to: window)
                return !$0.isHidden && frame.height > 0 && frame.minX <= window.bounds.midX
                    && frame.maxX >= window.bounds.midX && frame.intersects(window.bounds)
            }) else { throw failure("Missing visible native navigation bar") }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let url = URL.documentsDirectory.appendingPathComponent("scrolling-title-\(appearance)-\(phase).png")
            guard let pixels = image.cgImage, let data = image.pngData() else { throw failure("Could not capture \(phase)") }
            try data.write(to: url)
            return (pixels, bar.convert(bar.bounds, to: window).intersection(window.bounds))
        }

        func checkTitle(_ phase: String) throws {
            let (image, frame) = try capture(phase)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.regionOfInterest = CGRect(x: frame.minX / window.bounds.width,
                y: 1 - frame.maxY / window.bounds.height,
                width: frame.width / window.bounds.width, height: frame.height / window.bounds.height)
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            guard visible.contains(title), !visible.contains("Work") else {
                throw failure("Expected \(title) in the \(appearance) navigation bar during \(phase). Found \(visible)")
            }
        }
        try checkTitle("text-before-search")

        let backend = runtime.renderer.backend
        func nodes(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(nodes)
        }
        guard let searchNode = backend.rootIDs.flatMap(nodes).first(where: {
            backend.extensionModel(id: $0)?.identifier == "native-search-presentation"
        }) else { throw failure("Missing search presentation") }
        func controllers(_ viewController: UIViewController) -> [UIViewController] {
            [viewController] + viewController.children.flatMap(controllers)
        }
        func nativeSearch() -> UISearchController? {
            window.rootViewController.map(controllers)?.compactMap { $0.navigationItem.searchController }.first
        }
        let offsetBeforeSearch = scroll.contentOffset.y
        try backend.performExtensionEvent(node: searchNode, name: "present", values: [:])
        for _ in 0..<100 {
            if nativeSearch()?.isActive == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let search = nativeSearch(), search.isActive else { throw failure("UIKit search did not open") }
        search.isActive = false
        for _ in 0..<100 {
            if nativeSearch() == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard nativeSearch() == nil else { throw failure("UIKit search did not dismiss") }
        try await Task.sleep(for: .milliseconds(600))
        guard abs(scroll.contentOffset.y - offsetBeforeSearch) < 2, observed == title else {
            throw failure("Dismissing search must restore both the scroll position and the contextual title in \(appearance)")
        }
        try checkTitle("text-after-search")

        scroll.setContentOffset(CGPoint(x: 0, y: top + 310), animated: false)
        try await Task.sleep(for: .milliseconds(700))
        try checkTitle("image-after-search")
        scroll.setContentOffset(CGPoint(x: 0, y: top), animated: false)
        try await Task.sleep(for: .milliseconds(700))
        guard observed == nil else { throw failure("Returning to the content heading must clear the toolbar title") }
        _ = try capture("top")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "ScrollingNavigationTitle", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
