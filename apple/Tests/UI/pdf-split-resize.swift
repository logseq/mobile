import PDFKit
import UIKit
@testable import Logseq

@main struct PDFSplitResizeCheck {
    @MainActor static func main() async throws {
        let file = URL.temporaryDirectory.appendingPathComponent("pdf-resize-check.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).writePDF(to: file) { context in
            context.beginPage()
            NSString(string: "Keep reading while resizing").draw(at: CGPoint(x: 30, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let rect: [String: Double] = ["x1": 30, "y1": 100, "x2": 280, "y2": 128, "width": 600, "height": 800]
        let highlights = (0..<40).map { index in
            ["id": "highlight-\(index)", "page": 1, "content": ["text": "Keep reading"],
             "properties": ["color": "yellow"], "position": ["page": 1, "bounding": rect, "rects": [rect]]] as [String: Any]
        }
        let reader = LGPDFReaderController()
        reader.apply(["assetUuid": "resize-fixture", "graphId": "resize-check", "path": file.path,
                      "title": "Reading.pdf", "page": 1, "loading": false, "highlights": highlights])
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        let parent = UIViewController()
        window.rootViewController = parent
        window.makeKeyAndVisible()
        parent.addChild(reader)
        parent.view.addSubview(reader.view)
        reader.didMove(toParent: parent)
        reader.view.frame = CGRect(x: 0, y: 0, width: 330, height: 700)
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<100 {
            if reader.pdfView.document?.page(at: 0)?.annotations.count == highlights.count { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard let document = reader.pdfView.document, let page = document.page(at: 0), page.annotations.count == highlights.count else {
            throw failure("Annotations did not load")
        }
        let original = page.annotations
        let selection = page.selection(for: NSRange(location: 0, length: 12))!
        reader.pdfView.setCurrentSelection(selection, animate: false)
        let started = ProcessInfo.processInfo.systemUptime
        for width in stride(from: CGFloat(330), through: 490, by: 8) {
            reader.view.frame.size.width = width
            reader.view.setNeedsLayout()
            reader.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
            guard zip(original, page.annotations).allSatisfy({ $0 === $1 }), page.annotations.count == original.count else {
                throw failure("Resizing must preserve page annotations instead of removing and recreating them every frame")
            }
            guard reader.pdfView.document === document, reader.pdfView.currentSelection?.string == selection.string else {
                throw failure("Resizing must preserve the document and text selection")
            }
        }
        reader.pdfView.scaleFactor *= 1.2
        try await Task.sleep(for: .milliseconds(100))
        guard zip(original, page.annotations).allSatisfy({ $0 === $1 }) else {
            throw failure("Zooming must preserve native annotation objects")
        }
        print("PASS: continuous PDF resizing preserves annotation identity, selection and document; elapsed=\(ProcessInfo.processInfo.systemUptime - started)s")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "PDFSplitResize", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
