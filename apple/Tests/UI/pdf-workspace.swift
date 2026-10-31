import PDFKit
import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@main struct PDFWorkspaceCheck {
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
        let fixture = PDFDocument(url: url)!
        fixture.page(at: 1)!.rotation = 90
        fixture.page(at: 2)!.setBounds(CGRect(x: 20, y: 30, width: 540, height: 700), for: .cropBox)
        try fixture.dataRepresentation()!.write(to: url)
        let asset = "a9000000-0000-4000-8000-000000000001"
        let areaID = "a9000000-0000-4000-8000-000000000099"
        let areaBounds: [String: Double] = ["x1": 20, "y1": 200, "x2": 180, "y2": 260, "width": 600, "height": 800]
        var saved: [[String: Any]] = [["id": areaID, "page": 1, "content": ["image": "desktop-area"],
            "position": ["page": 1, "bounding": areaBounds, "rects": []], "properties": ["color": "yellow"]]]
        var requests: [[String: Any]] = []
        func snapshot(pdf: Bool = false, patch: Bool = false) -> String {
            var result: [String: Any] = ["graphName": "PDF workspace", "selectedGraphId": "pdf-test",
                "outlinerRows": [["depth": 0, "hasChildren": false, "isCollapsed": false,
                    "block": ["uuid": "main-note", "title": "Keep main available while reading", "pageId": "journal"]]]]
            if pdf {
                result["pdfWorkspace"] = ["assetUuid": asset, "graphId": "pdf-test", "highlights": saved, "page": 3]
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
                requests.append(command)
                if command["action"] as? String == "load" { try? await Task.sleep(for: .milliseconds(600)) }
                if command["action"] as? String == "save", let highlight = command["highlight"] as? [String: Any] {
                    saved.append(highlight)
                }
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
        let opening = String(decoding: try JSONSerialization.data(withJSONObject:
            ["uuid": asset, "title": "Research.pdf", "path": url.path]), as: UTF8.self)
        for cycle in 0..<3 {
            try runtime.applyHostUpdate(kind: "open-pdf", payload: opening)
            try await wait("Opening a PDF must show a native PDFView beside main") {
                views(window).contains { $0 is PDFView }
            }
            try await Task.sleep(for: .milliseconds(300))
            let pdf = views(window).compactMap { $0 as? PDFView }.first!
            pdf.scaleFactor = 1
            pdf.go(to: pdf.document!.page(at: 0)!)
            try await wait("A delayed annotation load must restore the last visited page") {
                pdf.currentPage.flatMap { pdf.document?.index(for: $0) } == 2
            }
            try await wait("Existing desktop area annotations must render their bounding rectangle") {
                pdf.document?.page(at: 0)?.annotations.contains { $0.userName == "logseq:" + areaID } == true
            }
            guard let fullScreenButton = views(window).compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == "pdf.toggle-fullscreen" }) else {
                throw failure("The PDF reader needs a visible full-screen and split-view switch")
            }
            let compact = window.bounds.width < 600
            let initialFrame = pdf.convert(pdf.bounds, to: window)
            guard compact ? initialFrame.width > window.bounds.width - 12 : initialFrame.maxX < window.bounds.width - 100 else {
                throw failure("PDFs must open full-screen on narrow windows and split on wide windows")
            }
            if compact {
                fullScreenButton.sendActions(for: .touchUpInside)
                try await wait("A narrow screen must still allow explicit split view") { pdf.bounds.width < window.bounds.width * 0.7 }
            }
            let splitWidth = pdf.bounds.width
            let originalDocument = pdf.document
            let originalMain = views(window).first { $0.accessibilityIdentifier == "outliner.block-action.main-note" }
            let originalPage = pdf.currentPage
            fullScreenButton.sendActions(for: .touchUpInside)
            try await wait("Full-screen PDF must occupy the entire content width") { pdf.bounds.width > window.bounds.width - 12 }
            guard pdf.document === originalDocument, pdf.currentPage === originalPage else {
                throw failure("Full-screen reading must preserve the document and reading page")
            }
            fullScreenButton.sendActions(for: .touchUpInside)
            try await wait("Returning to split must restore the previous column width") { abs(pdf.bounds.width - splitWidth) < 1 }
            guard views(window).first(where: { $0.accessibilityIdentifier == "outliner.block-action.main-note" }) === originalMain else {
                throw failure("Main must retain its native content while full-screen PDF is open")
            }
            guard let divider = views(window).first(where: { $0.accessibilityIdentifier == "pdf.divider" }), divider.bounds.width >= 44 else {
                throw failure("The split divider needs a real 44-point touch target")
            }
            for x in [CGFloat(2), divider.bounds.width - 2] {
                let point = divider.convert(CGPoint(x: x, y: divider.bounds.midY), to: window)
                guard let hit = window.hitTest(point, with: nil), hit === divider || hit.isDescendant(of: divider) else {
                    throw failure("The full divider touch area must win hit testing over the PDF and main")
                }
            }
            let beforeResize = pdf.bounds.width
            let documentBeforeResize = pdf.document
            divider.accessibilityIncrement()
            try await wait("Resizing must immediately give the PDF more width") { pdf.bounds.width > beforeResize + 20 }
            divider.accessibilityDecrement()
            try await wait("Resizing back must preserve the original split") { abs(pdf.bounds.width - beforeResize) < 1 }
            guard pdf.document === documentBeforeResize else { throw failure("Resizing must retain the PDF document") }
            let frame = pdf.convert(pdf.bounds, to: window)
            guard frame.width > 100, frame.maxX < window.bounds.width - 100 else {
                throw failure("The PDF must occupy the left column and leave main on the right: \(frame)")
            }
            guard host.presentedViewController == nil else { throw failure("PDF opening must not present Quick Look or a modal") }
            guard pdf.gestureRecognizers?.contains(where: {
                $0 is UIPanGestureRecognizer && $0.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            }) == true else { throw failure("Pencil text selection needs a direct pencil drag without hijacking finger scrolling") }
            let page = pdf.document!.page(at: cycle)!
            pdf.go(to: page)
            try await Task.sleep(for: .milliseconds(150))
            let selection = page.selection(for: NSRange(location: 0, length: 16))!
            let expectedBounds = selection.bounds(for: page)
            pdf.setCurrentSelection(selection, animate: false)
            guard let highlight = views(window).compactMap({ $0 as? UIButton }).first(where: {
                $0.accessibilityIdentifier == "pdf.highlight"
            }) else { throw failure("Missing an accessible highlight action") }
            let previous = saved.count
            highlight.sendActions(for: .touchUpInside)
            try await wait("Highlighting selected PDF text must dispatch a graph mutation") { saved.count == previous + 1 }
            guard saved.last?["content"] as? [String: String] == ["text": "Pencil selection"] else {
                throw failure("A highlight must preserve the selected text")
            }
            try await wait("Saved highlights must render on their original PDF page") {
                page.annotations.contains { $0.userName == "logseq:" + (saved.last?["id"] as? String ?? "") }
            }
            let annotation = page.annotations.first { $0.userName == "logseq:" + (saved.last?["id"] as? String ?? "") }!
            for rect in [annotation.bounds, expectedBounds] {
                guard rect.width.isFinite && rect.height.isFinite else { throw failure("Highlight geometry must stay finite") }
            }
            guard abs(annotation.bounds.minX - expectedBounds.minX) < 1,
                  abs(annotation.bounds.minY - expectedBounds.minY) < 1,
                  abs(annotation.bounds.width - expectedBounds.width) < 1 else {
                throw failure("Highlight coordinates drifted on normal, rotated or cropped page \(cycle + 1)")
            }
            pdf.scaleFactor *= 1.3
            try await Task.sleep(for: .milliseconds(150))
            guard let zoomed = page.annotations.first(where: { $0.userName == annotation.userName }),
                  abs(zoomed.bounds.minX - expectedBounds.minX) < 1 else {
                throw failure("Zooming must not move persisted highlights")
            }
            pdf.setCurrentSelection(selection, animate: false)
            try await wait("A new text selection must stop targeting the previous highlight") {
                views(window).compactMap { $0 as? UIButton }.first {
                    $0.accessibilityIdentifier == "pdf.copy-reference"
                }?.isEnabled == false
            }
            pdf.clearSelection()
            guard let close = views(window).compactMap({ $0 as? UIButton }).first(where: {
                $0.accessibilityIdentifier == "pdf.close"
            }) else { throw failure("Missing PDF close action") }
            if cycle == 0 {
                let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try screenshot.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("pdf-workspace.png"))
            }
            close.sendActions(for: .touchUpInside)
            try await wait("Closing the PDF must restore the full-width main") { !views(window).contains { $0 is PDFView } }
        }
        guard requests.allSatisfy({ $0["graphId"] as? String == "pdf-test" && $0["assetUuid"] as? String == asset }) else {
            throw failure("Annotation operations must keep their graph and asset identity")
        }
        guard runtime.lastError == nil else { throw failure(runtime.lastError!) }
        print("PASS: PDF/main split, Pencil selection gesture, text highlights on normal/rotated/cropped pages, zoom and reopening")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "PDFWorkspace", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
