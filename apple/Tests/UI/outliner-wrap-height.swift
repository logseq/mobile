import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class WrapEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct OutlinerWrapHeightCheck {
    @MainActor static func main() async throws {
        var title = "Das ist ein Test, um das Problem zu reproduzieren. Das Problem mit dem abgeschnittenen Text kommt wohl nur auf der zweiten Ebene"
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: WrapEffects())
        func snapshot(indented: Bool, editing: Bool) throws -> String {
            let rows: [[String: Any]] = [
                ["depth": 0, "hasChildren": indented, "block": ["uuid": "parent", "title": title, "pageId": "page"]],
                ["depth": indented ? 1 : 0, "block": ["uuid": "child", "title": title, "pageId": "page"]],
                ["depth": 0, "block": ["uuid": "next", "title": "A", "pageId": "page"]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": [
                "selectedGraphId": "demo", "graphName": "Demo", "outlinerRows": indented ? [] : rows,
                "isOutlinerPatch": indented,
                "outlinerRowSplices": indented ? [["start": 0, "deleteCount": 3, "rows": rows]] : [],
                "outlinerState": ["editing": editing ? ["uuid": "child", "title": title, "caretUTF16Offset": title.utf16.count] as Any : NSNull(), "selectedBlockIds": []]
            ]]), as: UTF8.self)
        }
        try runtime.applyCoreResponse(snapshot(indented: false, editing: false))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; runtime.stop() }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func label(_ uuid: String) throws -> UILabel {
            guard let label = views(window).compactMap({ $0 as? UILabel }).first(where: {
                $0.accessibilityIdentifier == "outliner.block-action." + uuid
            }) else { throw failure("Missing title " + uuid) }
            return label
        }
        var errors: [String] = []
        func check(_ phase: String, editing: Bool) throws {
            host.view.layoutIfNeeded()
            let next = try label("next").convert(try label("next").bounds, to: window)
            for uuid in ["parent", "child"] {
                if let label = try? label(uuid), let row = label.superview as? OutlinerTextRowView {
                    let required = row.sizeThatFits(CGSize(width: row.bounds.width, height: .greatestFiniteMagnitude)).height
                    if abs(row.intrinsicContentSize.height - required) > 1 {
                        errors.append("\(phase): native row invalidation must publish its current fitting height (\(row.intrinsicContentSize.height) != \(required))")
                    }
                    let storage = NSTextStorage(string: label.attributedText?.string ?? "", attributes: [.font: label.font as Any])
                    let manager = NSLayoutManager()
                    let container = NSTextContainer(size: CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                    container.lineFragmentPadding = 0
                    storage.addLayoutManager(manager); manager.addTextContainer(container)
                    manager.ensureLayout(for: container)
                    let glyphs = manager.boundingRect(forGlyphRange: manager.glyphRange(for: container), in: container)
                    if glyphs.maxY > label.bounds.height + 1 { errors.append("\(phase): \(uuid) drawn glyphs exceed its measured height (\(glyphs.maxY) > \(label.bounds.height))") }
                    print("WRAP \(phase) \(uuid) row=\(row.frame) required=\(required) label=\(label.frame)")
                    if row.bounds.height + 1 < required { errors.append("\(phase): \(uuid) retained stale height \(row.bounds.height), needs \(required)") }
                    if row.convert(row.bounds, to: window).maxY > next.minY + 1 { errors.append("\(phase): \(uuid) overlaps the following block") }
                }
            }
            let editor = views(window).compactMap({ $0 as? UITextView }).first(where: { $0.text == title })
            if editing && editor == nil { errors.append("\(phase): missing editor with the current draft") }
            if let editor {
                editor.layoutManager.ensureLayout(for: editor.textContainer)
                let glyphs = editor.layoutManager.usedRect(for: editor.textContainer)
                let required = glyphs.maxY + editor.textContainerInset.top
                if editor.bounds.height + 1 < required { errors.append("\(phase): editor clips its final line (\(editor.bounds.height) < \(required))") }
                if editor.convert(CGPoint(x: 0, y: required), to: window).y > next.minY + 1 { errors.append("\(phase): editor overlaps the following block") }
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try image.pngData()!.write(to: documents.appendingPathComponent("wrap-\(phase).png"))
        }
        try await Task.sleep(for: .milliseconds(700))
        let sample = try label("parent")
        let width = sample.superview!.bounds.width
        let words = title.split(separator: " ")
        // Pick a real wrap boundary at this device's width and Dynamic Type size.
        for count in 1...words.count {
            let candidate = words.prefix(count).joined(separator: " ")
            func height(_ inset: CGFloat) -> CGFloat {
                OutlinerNativeTextMeasurement.size(text: candidate, font: sample.font,
                    width: width - 26 - inset, verticalInset: 0, scale: 3).height
            }
            if height(0) > sample.font.lineHeight * 2 && height(22) > height(0) + 10
                && height(44) > height(0) + 10 { title = candidate; break }
        }
        try runtime.applyCoreResponse(snapshot(indented: false, editing: true))
        try await Task.sleep(for: .milliseconds(300))
        let original = try label("parent").superview
        let initialHeight = try label("parent").superview!.bounds.height
        let originalEditor = views(window).compactMap { $0 as? UITextView }.first { $0.text == title }
        try check("before", editing: true)
        for (index, editing) in [true, false, true].enumerated() {
            try runtime.applyCoreResponse(snapshot(indented: true, editing: editing))
            try await Task.sleep(for: .milliseconds(400))
            try check(editing ? "editing" : "indented", editing: editing)
            if try label("parent").superview!.bounds.height < initialHeight + 10 {
                errors.append("The fixture must wrap to an extra line after indentation")
            }
            if index == 0, let editor = views(window).compactMap({ $0 as? UITextView }).first(where: { $0.text == title }),
               let originalEditor, editor !== originalEditor { errors.append("Indenting must retain the native editor") }
            if try label("parent").superview !== original { errors.append("Indenting must retain the parent row") }
        }
        guard errors.isEmpty else { throw failure(errors.joined(separator: "\n")) }
        print("PASS: retained native rows and editor reflow after indentation without clipping or overlap")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "OutlinerWrapHeight", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
