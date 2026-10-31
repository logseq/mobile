import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class LayoutEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution { .init(succeeded: true, message: "", output: .discard) }
}

@main struct PDFAnnotationLayoutCheck {
    @MainActor static func main() async throws {
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LayoutEffects())
        let rows: [[String: Any]] = ["normal", "annotation", "following"].map { id in
            var block: [String: Any] = ["uuid": id, "title": "A short line", "pageId": "page"]
            if id == "annotation" { block["pdfAnnotation"] = ["id": id, "page": 1, "assetUuid": "asset", "assetTitle": "Reading.pdf"] }
            return ["depth": 1, "block": block]
        }
        let response = String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": ["selectedGraphId": "layout", "graphName": "Layout", "outlinerRows": rows]]), as: UTF8.self)
        try runtime.applyCoreResponse(response)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
        func descendants(_ id: Int) -> [Int] { [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants) }
        func frame(_ uuid: String) throws -> CGRect {
            guard let id = backend.rootIDs.flatMap(descendants).first(where: { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == "outliner.block." + uuid }), let frame = frames[id] else { throw failure("Missing row frame") }
            return frame
        }
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; runtime.stop() }
        try await Task.sleep(for: .milliseconds(600))
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        guard let prefix = views(window).compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == "pdf.annotation-page.annotation" }),
              let text = views(window).first(where: { $0.accessibilityIdentifier == "outliner.block-action.normal" }) else { throw failure("Missing row content") }
        let normal = try frame("normal")
        let annotation = try frame("annotation")
        print("ANNOTATION_LAYOUT normal=\(normal) annotation=\(annotation)")
        guard annotation.height <= normal.height + 1 else { throw failure("The page link touch target must not add blank space below an annotation") }
        guard let label = prefix.titleLabel else { throw failure("Missing page label") }
        let labelFrame = label.convert(label.bounds, to: window)
        let normalFrame = text.convert(text.bounds, to: window)
        guard abs(labelFrame.minX - normalFrame.minX) <= 1 else { throw failure("The pin must align with normal block text without extra leading padding") }
        guard prefix.bounds.height >= 44 else { throw failure("The compact row must retain its 44-point page-link touch target") }
        print("PASS: annotation prefixes align with ordinary text and retain compact row spacing and touch targets")
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "PDFAnnotationLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
