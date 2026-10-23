import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class PositionEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct OutlinerEditingPositionCheck {
    @MainActor static func main() async throws {
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: PositionEffects())
        func snapshot(_ title: String, editing: Bool, added: Bool = false) throws -> String {
            var result: [String: Any] = ["selectedGraphId": "demo", "graphName": "Demo",
                "outlinerRows": [["depth": 0, "block": ["uuid": "body", "title": title, "pageId": "page", "journalTitle": "Today", "journalDay": 20261023]]]]
            if added { result["outlinerRows"] = (result["outlinerRows"] as! [[String: Any]]) + [["depth": 0, "block": ["uuid": "created", "title": "", "pageId": "page", "journalTitle": "Today", "journalDay": 20261023]]] }
            result["outlinerState"] = editing
                ? ["editing": ["uuid": added ? "created" : "body", "title": added ? "" : title, "caretUTF16Offset": added ? 0 : title.utf16.count]]
                : ["selectedBlockIds": []]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        try runtime.applyCoreResponse(snapshot("Hello", editing: false))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier }
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer).ignoresSafeArea(.keyboard))
        window.makeKeyAndVisible()
        window.overrideUserInterfaceStyle = .light
        defer { runtime.stop(); window.isHidden = true }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func capture(_ name: String) throws -> UIImage {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(name + ".png"))
            return image
        }
        func firstInkY(_ image: UIImage, frame: CGRect) -> CGFloat {
            let cg = image.cgImage!
            let bytes = CFDataGetBytePtr(cg.dataProvider!.data!)!
            let scale = image.scale
            for y in Int(frame.minY * scale)..<Int((frame.minY + 24) * scale) {
                var count = 0
                for x in Int(frame.minX * scale)..<Int((frame.minX + 30) * scale) {
                    let i = y * cg.bytesPerRow + x * 4
                    if max(bytes[i], bytes[i+1], bytes[i+2]) < 140 { count += 1 }
                }
                if count >= 5 { return CGFloat(y) / scale }
            }
            fatalError("Missing text pixels")
        }
        var shifts: [CGFloat] = []
        for (index, title) in ["Hello", "Hello world. A wrapped line of plain text with enough words to occupy several lines on a narrow phone."].enumerated() {
            try runtime.applyCoreResponse(snapshot(title, editing: false))
            try await Task.sleep(for: .milliseconds(450))
            window.layoutIfNeeded()
            guard let label = views(window).compactMap({ $0 as? UILabel }).first(where: { $0.accessibilityIdentifier == "outliner.block-action.body" }) else { fatalError("Missing display label") }
            let displayFrame = label.convert(label.bounds, to: window)
            let displayBullet = views(window).first { $0.accessibilityIdentifier?.hasPrefix("button.outliner.zoom.body.") == true }!
            let displayBulletFrame = displayBullet.convert(displayBullet.bounds, to: window)
            let beforeImage = try capture("display-\(index)")
            let displayInk = firstInkY(beforeImage, frame: displayFrame)
            try runtime.applyCoreResponse(snapshot(title, editing: true))
            try await Task.sleep(for: .milliseconds(500))
            window.layoutIfNeeded()
            guard let editor = views(window).compactMap({ $0 as? UITextView }).first(where: { $0.accessibilityIdentifier == "field.outliner.block.body" }) else { fatalError("Missing editor") }
            let editFrame = editor.convert(editor.bounds, to: window)
            print("POSITION case=\(index) display=\(displayFrame) editor=\(editFrame) inset=\(editor.textContainerInset) bullet=\(displayBulletFrame)")
            precondition(displayFrame == editFrame, "The complete title frame must remain unchanged")
            let afterImage = try capture("editing-\(index)")
            let editInk = firstInkY(afterImage, frame: editFrame)
            print("INK case=\(index) display=\(displayInk) editing=\(editInk) shift=\(editInk - displayInk)")
            shifts.append(editInk - displayInk)
        }
        try runtime.applyCoreResponse(snapshot("Hello", editing: false))
        try await Task.sleep(for: .milliseconds(450))
        window.layoutIfNeeded()
        guard let placeholder = find("outliner.placeholder.bullet.page").flatMap({ frames[$0] }) else { fatalError("Missing placeholder frame") }
        try runtime.applyCoreResponse(snapshot("Hello", editing: true, added: true))
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        let created = views(window).compactMap({ $0 as? UITextView }).first { $0.accessibilityIdentifier == "field.outliner.block.created" }!
        let createdFrame = created.convert(created.bounds, to: window)
        print("PLACEHOLDER before=\(placeholder) createdEditor=\(createdFrame)")
        guard find("button.outliner.placeholder.page") == nil,
              abs(placeholder.minX - (createdFrame.minX - 26)) <= 0.1,
              abs(placeholder.minY - createdFrame.minY) <= 0.1 else {
            throw NSError(domain: "EditingPosition", code: 2, userInfo: [NSLocalizedDescriptionKey: "The placeholder bullet must keep its position when it becomes an editor"])
        }
        guard shifts.allSatisfy({ abs($0) <= 0.1 }) else {
            throw NSError(domain: "EditingPosition", code: 1, userInfo: [NSLocalizedDescriptionKey: "Entering edit mode must preserve the text baseline: \(shifts)"])
        }
        print("PASS: single-line and wrapped display text retain their baseline while editing")
    }
}
