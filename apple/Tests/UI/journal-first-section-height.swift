import SwiftUI
import UIKit
import Vision
@testable import LUIAppleBackend

@main struct JournalFirstSectionHeightCheck {
    @MainActor static func main() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        for empty in [false, true] {
            let backend = LUIAppleBackend()
            let sectionCount = empty ? 1 : 2
            let metadata = "data-virtual-count\u{1f}70\u{1e}data-virtual-start\u{1f}0\u{1e}data-virtual-length\u{1f}70\u{1e}data-item-extent\u{1f}32\u{1e}data-first-section-count\u{1f}\(sectionCount)\u{1e}data-first-section-inset\u{1f}100"
            var ops: [[String: Any]] = [
                ["op": "create-node", "id": 1, "kind": "virtual-list"],
                ["op": "set-prop", "id": 1, "property": "selected", "value": true],
                ["op": "create-node", "id": 2, "kind": "list"],
                ["op": "set-prop", "id": 2, "property": "data-attrs", "value": metadata],
                ["op": "insert-child", "parent": 1, "child": 2, "index": 0]]
            for index in 0..<70 {
                let row = 10 + index * 2
                let height = index == 1 && !empty ? 28 : 80
                let title = index == 0 ? "Today" : index == sectionCount ? "Previous" : "Earlier entry \(index)"
                ops += [["op": "create-node", "id": row, "kind": "column"],
                        ["op": "set-prop", "id": row, "property": "height", "value": height],
                        ["op": "create-node", "id": row + 1, "kind": "text"],
                        ["op": "set-prop", "id": row + 1, "property": "text", "value": title],
                        ["op": "set-prop", "id": row + 1, "property": "font-size", "value": "22"],
                        ["op": "insert-child", "parent": row, "child": row + 1, "index": 0],
                        ["op": "insert-child", "parent": 2, "child": row, "index": index]]
            }
            try backend.apply(json: String(decoding: JSONSerialization.data(withJSONObject: ["generation": 1, "ops": ops]), as: UTF8.self))
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView:
                LUISwiftUIRoot(backend: backend, rootID: 1)
                    .frame(width: 320, height: 500)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
            try await Task.sleep(for: .milliseconds(800))
            guard let scroll = views(window).compactMap({ $0 as? UIScrollView }).first else { throw failure("Missing journal scroller") }
            func screenshot(_ name: String) throws -> UIImage {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("journal-height-\(empty ? "empty" : "short")-\(name).png"))
                return image
            }
            func journalHeight(_ image: UIImage) throws -> CGFloat {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: image.cgImage!).perform([request])
                let lines = request.results ?? []
                func y(_ text: String) throws -> CGFloat {
                    guard let line = lines.first(where: { $0.topCandidates(1).first?.string == text }) else {
                        throw failure("Missing visible heading \(text): \(lines.compactMap { $0.topCandidates(1).first?.string })")
                    }
                    return (1 - line.boundingBox.midY) * window.bounds.height
                }
                return try y("Previous") - y("Today")
            }
            let initial = try journalHeight(screenshot("before"))
            var heights = [initial]
            for cycle in 0..<3 {
                for y in stride(from: 0, through: 2400, by: 120) {
                    scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                    try await Task.sleep(for: .milliseconds(35))
                }
                for y in stride(from: 2400, through: 0, by: -120) {
                    scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                    try await Task.sleep(for: .milliseconds(35))
                }
                scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
                try await Task.sleep(for: .milliseconds(300))
                heights.append(try journalHeight(screenshot("after-\(cycle)")))
            }
            print("JOURNAL_HEIGHT empty=\(empty) measured=\(heights)")
            guard heights.allSatisfy({ abs($0 - initial) <= 2 }) else {
                throw failure("Today's journal must keep its rendered height across scrolling: \(heights)")
            }
            guard abs(initial - 400) <= 2 else { throw failure("The current journal must fill the viewport minus its chrome inset: \(initial)") }
        }
        print("PASS: short and empty current journals keep their rendered height across repeated lazy-row recycling")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "JournalFirstSectionHeight", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
