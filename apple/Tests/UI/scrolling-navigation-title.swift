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
        print("PASS: the graph switch stays visible alongside the page title while scrolling after warm and cold loads")
    }

    @MainActor static func check(delayedLoad: Bool) async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let title = "Project page"
        let rows: [[String: Any]] = (0..<60).map { index in
            ["block": ["uuid": "row-\(index)", "title": "Body row \(index)", "pageId": "page"], "depth": 0]
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
        if !delayedLoad { try runtime.applyHostUpdate(kind: "graph-loading", payload: "false") }
        var observed: String?
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer)
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
        guard let bar = views(window).compactMap({ $0 as? UINavigationBar }).first(where: {
            let frame = $0.convert($0.bounds, to: window)
            return !$0.isHidden && frame.height > 0 && frame.minX <= window.bounds.midX
                && frame.maxX >= window.bounds.midX && frame.intersects(window.bounds)
        }) else { throw failure("Missing visible native navigation bar") }
        let frame = bar.convert(bar.bounds, to: window).intersection(window.bounds)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("scrolling-title-\(delayedLoad ? "cold" : "warm")-page.png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.regionOfInterest = CGRect(x: frame.minX / window.bounds.width,
            y: 1 - frame.maxY / window.bounds.height,
            width: frame.width / window.bounds.width, height: frame.height / window.bounds.height)
        try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
        let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        guard visible.contains(title), visible.contains("Work") else {
            throw failure("The native top bar must display the graph and \(title) after \(delayedLoad ? "cold" : "warm") loading; found: \(visible)")
        }
        scroll.setContentOffset(CGPoint(x: 0, y: top), animated: false)
        try await Task.sleep(for: .milliseconds(700))
        guard observed == nil else { throw failure("Returning to the content heading must clear the toolbar title") }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "ScrollingNavigationTitle", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
