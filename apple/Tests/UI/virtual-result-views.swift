import SwiftUI
import UIKit
import Vision
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class VirtualResultEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct VirtualResultViewsCheck {
    @MainActor static func main() async throws {
        let count = 10_001
        func snapshot(_ type: String, ready: Bool = true) throws -> String {
            let rows: [[String: Any]] = (0..<count).map { index in
                let title = String(format: "Object %05d", index)
                return ["block": ["uuid": "object-\(index)", "title": title, "pageId": "page"],
                        "properties": [["attr": "block/title", "text": title, "editable": true,
                                        "raw": ["type": "string", "value": title]],
                                       ["attr": "user.property/Ready", "text": String(ready), "editable": true,
                                        "raw": ["type": "bool", "value": ready]]]]
            }
            let query: [String: Any] = [
                "ownerUuid": "owner", "featureType": "query-result", "expanded": true,
                "views": [["uuid": "virtual", "name": "All", "type": type, "rows": rows,
                           "columns": [["attr": "block/title", "title": "Name", "editable": true],
                                       ["attr": "user.property/Ready", "title": "Ready", "kind": "checkbox", "editable": true]]]]
            ]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": [
                "selectedGraphId": "virtual-check", "graphName": "Virtual result check",
                "outlinerRows": [["depth": 0, "hasChildren": false, "isCollapsed": false,
                                  "block": ["uuid": "owner", "title": "Large query", "pageId": "page", "query": query]]]
            ]]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: VirtualResultEffects())
        try runtime.applyCoreResponse(snapshot("table"))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        backend.frameReportingEnabled = true
        var frames: [Int: CGRect] = [:]
        backend.onFramesReport = { frames = $0 }
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func fail(_ message: String) -> NSError { NSError(domain: "VirtualResults", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            if message.hasPrefix("Value updates") {
                let node = find("view.cell.virtual.object-10000.user.property/Ready")
                let source = find("view.window.virtual").flatMap { backend.model(id: $0)?.property(.dataAttrs)?.stringValue }
                print("REFRESH_DIAGNOSTIC value=\(node.flatMap { backend.model(id: $0)?.text } ?? "missing") window=\(source ?? "missing")")
            }
            throw fail(message + "; " + (runtime.lastError ?? "no runtime error"))
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true; window.rootViewController = nil }
        func allViews(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(allViews) }
        func capture(_ name: String, containing title: String) async throws {
            try await Task.sleep(for: .milliseconds(500))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(name))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            guard text.contains(title) else { throw fail("Visible result missing \(title): \(text)") }
        }
        for type in ["table", "gallery"] {
            if type == "gallery" { try runtime.applyCoreResponse(snapshot(type)) }
            try await wait("A 10k \(type) result must expose its virtual window") { find("view.window.virtual") != nil }
            let first = type == "table" ? "view.cell.virtual.object-0.block/title" : "view.card.virtual.object-0"
            let last = type == "table" ? "view.cell.virtual.object-10000.block/title" : "view.card.virtual.object-10000"
            try await wait("The first result must mount") { find(first) != nil }
            guard find(last) == nil else { throw fail("Distant rows must not mount before scrolling") }
            let viewportID = type == "table" ? "view.table.viewport.virtual" : "view.gallery.virtual"
            try await wait("The native result viewport must lay out") {
                find(viewportID).flatMap { frames[$0] }?.height ?? 0 > 0
            }
            try await Task.sleep(for: .milliseconds(500))
            let viewport = frames[find(viewportID)!]!
            guard let scroll = allViews(window).compactMap({ $0 as? UIScrollView }).first(where: {
                abs($0.bounds.height - viewport.height) < 2 && $0.contentSize.height > 10_000
            }) else { throw fail("The result must have a native lazy vertical scroller") }
            try await capture("virtual-\(type)-first.png", containing: "Object 00000")
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
            try await wait("Native scrolling must load the last \(type) result") { find(last) != nil }
            guard find(first) == nil else { throw fail("Scrolled-away protocol nodes must be evicted") }
            guard backend.model(id: find("view.window.virtual")!)!.children.count <= 32 else { throw fail("The live window grew without bounds") }
            try await capture("virtual-\(type)-last.png", containing: "Object 10000")
            if type == "table" {
                try backend.performPress(node: find("view.cell.virtual.object-10000.user.property/Ready")!)
                try await wait("A recycled distant cell must open its typed editor") { find("view.edit.sheet.virtual") != nil }
                try backend.performPress(node: find("view.edit.cancel.virtual")!)
                try await wait("The native cell editor must finish dismissing") {
                    window.rootViewController?.presentedViewController == nil
                }
            }
            let retainedViewport = find(viewportID)
            try runtime.applyCoreResponse(snapshot(type, ready: false))
            try await wait("Value updates must refresh the distant \(type) row without evicting it") {
                let value = type == "table" ? find("view.cell.virtual.object-10000.user.property/Ready") : find(last)
                return value.map { descendants($0).contains { backend.model(id: $0)?.text == "false" } } ?? false
            }
            guard find(viewportID) == retainedViewport, scroll.window != nil, scroll.contentOffset.y > 5_000 else {
                throw fail("Value refreshes must retain the native viewport and scroll position")
            }
            scroll.setContentOffset(.zero, animated: false)
            try await wait("Scrolling back must restore the first \(type) result") { find(first) != nil }
            try await capture("virtual-\(type)-return.png", containing: "Object 00000")
        }
        print("PASS: native table/gallery scroll through 10k results with bounded nodes, visible final rows and distant cell editing")
    }
}
