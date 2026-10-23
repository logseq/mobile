import SwiftUI
import UIKit
import Vision
@testable import Logseq
@testable import LUIAppleBackend

@MainActor private final class QueryDisclosureEffects: LGEffectExecuting {
    var snapshot: ((Bool) throws -> String)!
    var expansions: [Bool] = []
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        guard effect.kind == "result-view" else {
            return LGEffectResolution(succeeded: true, message: "", output: .discard)
        }
        do {
            let input = try JSONSerialization.jsonObject(with: Data(effect.text.utf8)) as! [String: Any]
            let expanded = input["expanded"] as! Bool
            expansions.append(expanded)
            return LGEffectResolution(succeeded: true, message: try snapshot(expanded))
        } catch { return LGEffectResolution(succeeded: false, message: String(describing: error)) }
    }
}

@main struct QueryDisclosureLifecycleCheck {
    @MainActor static func main() async throws {
        for zoomed in [false, true] {
            func snapshot(_ expanded: Bool) throws -> String {
                let rows: [[String: Any]] = expanded ? (0..<2).map { index in
                    ["block": ["uuid": "result-\(index)", "title": "Project item \(index + 1)", "pageId": "page"]]
                } : []
                var query: [String: Any] = ["ownerUuid": "query-owner", "featureType": "query-result",
                    "kind": expanded ? "simple" : "deferred", "expanded": expanded, "rows": rows, "views": []]
                if expanded {
                    query["views"] = [["uuid": "query-owner:default", "name": "All", "type": "list", "rows": rows,
                                       "columns": [], "error": NSNull()]]
                }
                let outline: [[String: Any]] = [["depth": 0, "hasChildren": false, "isCollapsed": false,
                    "block": ["uuid": "query-owner", "title": "Project query", "pageId": "page", "query": query]]]
                var result: [String: Any] = ["selectedGraphId": "query-disclosure", "graphName": "Queries"]
                if zoomed {
                    result["nodeRoutes"] = [["uuid": "query-owner", "page": ["uuid": "page", "title": "Workspace"],
                                              "outlinerRows": outline]]
                } else { result["outlinerRows"] = outline }
                return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
            }
            let effects = QueryDisclosureEffects()
            effects.snapshot = snapshot
            let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
            try runtime.applyCoreResponse(snapshot(false))
            try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
            try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
            if zoomed { try runtime.applyHostUpdate(kind: "open-node", payload: "\"query-owner\"") }
            let backend = runtime.renderer.backend
            var frames: [Int: CGRect] = [:]
            backend.frameReportingEnabled = true
            backend.onFramesReport = { frames = $0 }
            func ids(_ id: Int) -> [Int] {
                [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(ids)
            }
            func find(_ identifier: String) -> Int? {
                backend.rootIDs.flatMap(ids).last {
                    backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
                }
            }
            func wait(_ message: String, until predicate: () -> Bool) async throws {
                for _ in 0..<100 {
                    if predicate() { return }
                    try await Task.sleep(for: .milliseconds(20))
                }
                throw failure(message + "; runtime=" + (runtime.lastError ?? "none"))
            }
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
            func visibleText(_ phase: String) async throws -> String {
                try await Task.sleep(for: .milliseconds(350))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("query-disclosure-\(zoomed)-\(phase).png"))
                guard let icon = find("query.disclosure.query-owner"), let frame = frames[icon],
                      abs(frame.width - 10) < 0.5, abs(frame.height - 10) < 0.5 else {
                    throw failure("The query disclosure must actually render at the block's 10pt icon size")
                }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            }
            try await wait("Query must mount") { find("query.toggle.query-owner") != nil }
            let folded = try await visibleText("folded")
            guard folded.contains("Project query"), folded.contains("Results"), effects.expansions.isEmpty else {
                throw failure("A deferred query must show its native Results label without executing: \(folded)")
            }
            try backend.performPress(node: find("query.toggle.query-owner")!)
            try await wait("Expanding executes and displays results") { find("query.result.query-owner.1") != nil }
            guard try await visibleText("expanded").contains("2 results"), effects.expansions == [true] else {
                throw failure("Expanded query must display the updated result count")
            }
            try backend.performPress(node: find("query.toggle.query-owner")!)
            try await wait("Folding removes results") { find("query.result.query-owner.0") == nil }
            guard try await visibleText("refolded").contains("Results"), effects.expansions == [true, false] else {
                throw failure("Folded query must restore its Results label")
            }
            try backend.performPress(node: find("query.toggle.query-owner")!)
            try await wait("Reopening executes again") { effects.expansions == [true, false, true] && find("query.result.query-owner.1") != nil }
        }
        print("PASS: deferred queries show native Results labels, expand, update counts, fold and rerun in pages and zoomed blocks")
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "QueryDisclosureLifecycleCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
