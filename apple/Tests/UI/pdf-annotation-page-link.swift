import PDFKit
import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@main struct PDFAnnotationPageLinkCheck {
    @MainActor static func main() async throws {
        let url = URL.temporaryDirectory.appendingPathComponent("PDF-workspace-check.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800))
            .writePDF(to: url) { context in
                for page in 1...3 {
                    context.beginPage()
                    NSString(string: "Pencil selection on page \(page)").draw(
                        at: CGPoint(x: 40, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
                }
            }
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = "a9000000-0000-4000-8000-000000000001"
        let annotations = [("a9000000-0000-4000-8000-000000000002", 2), ("a9000000-0000-4000-8000-000000000003", 3)]
        func snapshot(pdf: Bool = false, patch: Bool = false) -> String {
            var rows: [[String: Any]] = [["depth": 0, "hasChildren": true, "block": ["uuid": asset, "title": "Research.pdf", "pageId": "journal", "isAsset": true, "assetType": "pdf", "localPath": url.path]]]
            rows += annotations.map { id, page in
                ["depth": 1, "hasChildren": false, "block": ["uuid": id, "title": "A selected passage on page \(page)", "pageId": "journal", "pdfAnnotation": ["id": id, "assetUuid": asset, "assetTitle": "Research.pdf", "page": page, "color": "yellow"]]]
            }
            var result: [String: Any] = ["graphName": "Annotation links", "selectedGraphId": "pdf-test", "outlinerRows": rows]
            if pdf {
                result["pdfWorkspace"] = ["assetUuid": asset, "graphId": "pdf-test", "highlights": [], "page": 1]
                result["isPdfPatch"] = patch
            }
            return String(decoding: try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { request in
            if let payload = request.params.payload?.data(using: .utf8),
               let effect = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               effect["kind"] as? String == "pdf-annotation",
               let text = effect["text"] as? String,
               let data = text.data(using: .utf8),
               let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return snapshot(pdf: true, patch: true)
            }
            return snapshot()
        }))
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func wait(_ description: String, until condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw failure(description)
        }
        try await Task.sleep(for: .milliseconds(350))
        for (id, page) in annotations {
            guard let prefix = views(window).compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == "pdf.annotation-page." + id }) else {
                throw failure("Annotation blocks must show a clickable page prefix")
            }
            guard prefix.currentTitle?.contains("P\(page)") == true else { throw failure("Incorrect page label") }
            guard prefix.bounds.height >= 44 else { throw failure("The page prefix needs a mobile touch target") }
            prefix.sendActions(for: .touchUpInside)
            try await wait("The page prefix must open its PDF at page \(page), overriding last-visit-page") {
                guard let pdf = views(window).compactMap({ $0 as? PDFView }).first, let document = pdf.document else { return false }
                return pdf.currentPage.map { document.index(for: $0) } == page - 1
            }
            guard host.presentedViewController == nil else { throw failure("Page links must open the split workspace") }
            let current = views(window).compactMap { $0 as? PDFView }.first!
            guard current.document?.pageCount == 3 else { throw failure("The linked PDF must remain open") }
        }
        print("PASS: annotation page prefixes open the PDF and navigate between highlights while preserving main")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "PDFAnnotationPageLink", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
