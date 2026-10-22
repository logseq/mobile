import SwiftUI
import UIKit
import Vision
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class ObjectPageEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct ObjectPagesCheck {
    @MainActor static func main() async throws {
        func snapshot(_ kind: String) throws -> String {
            let result: [String: Any] = [
                "selectedGraphId": "object-pages", "graphName": "Object pages",
                "selectedPage": ["uuid": "collection", "title": "Collection"],
                "selectedPageIsTag": kind == "tag", "selectedPageIsProperty": kind == "property",
                "outlinerRows": [["depth": 0, "block": ["uuid": "page-child", "title": "Page child", "pageId": "collection"]]],
                "resultViews": ["ownerUuid": "collection", "featureType": "tagged", "views": [
                    ["uuid": "objects-view", "name": "All", "type": "list", "rows": [
                        ["block": ["uuid": "object-result", "title": "Visible object", "pageId": "elsewhere"]]
                    ]]
                ]]
            ]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: ObjectPageEffects())
        try runtime.applyCoreResponse(snapshot("tag"))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        func ids(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(ids)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(ids).first { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier }
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        for kind in ["tag", "property", "page", "tag"] {
            try runtime.applyCoreResponse(snapshot(kind))
            try await Task.sleep(for: .milliseconds(500))
            let ordinary = kind == "page"
            guard (find("outliner.block.page-child") != nil) == ordinary,
                  (find("button.outliner.placeholder.collection") != nil) == ordinary,
                  find("outliner.block.object-result") != nil else {
                throw NSError(domain: "ObjectPages", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Only ordinary pages may display page blocks and placeholders; objects must remain visible: " + kind])
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("objects-" + kind + ".png"))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image.cgImage!).perform([request])
            guard let text = request.results?.first(where: { $0.topCandidates(1).first?.string == "All" }) else {
                throw NSError(domain: "ObjectPages", code: 3, userInfo: [NSLocalizedDescriptionKey: "The native view selector must visibly render All"])
            }
            let x = text.boundingBox.minX * window.bounds.width
            let leading = window.safeAreaInsets.left + 16
            guard abs(x - leading) <= 3 else {
                throw NSError(domain: "ObjectPages", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    "All must align with the selector's leading edge: text=\(x), heading=\(leading)"])
            }
        }
        print("PASS: tag/property pages hide blocks and placeholders, ordinary pages retain them, and objects stay mounted")
    }
}
