import SwiftUI
import UIKit
import LogseqModel
@testable import Logseq
@testable import LUIAppleBackend

@MainActor private final class TapEffects: LGEffectExecuting {
    var caret: Int?
    var snapshot: ((Int?) throws -> String)!
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        guard effect.kind == "editor-outliner-event" else { return .init(succeeded: true, message: "", output: .discard) }
        let payload = try! JSONSerialization.jsonObject(with: Data(effect.text.utf8)) as! [String: Any]
        caret = payload["caretUTF16Offset"] as? Int
        return .init(succeeded: true, message: try! snapshot(caret))
    }
}

@main struct BlockTapCaretCheck {
    @MainActor static func main() async throws {
        let row = OutlinerTextRowView()
        row.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        var offsets: [Int] = []
        var opened: [URL] = []
        func update(_ text: String, markup: [[String: Any]] = []) throws -> UILabel {
            let json: [String: Any] = ["uuid": "body", "title": text, "markup": markup,
                "depth": 0, "hasChildren": false, "collapsed": false, "isAsset": false,
                "assetType": "", "localPath": "", "youtubeURL": "", "completed": false,
                "selected": false, "opensAsPage": false, "journalBullet": false,
                "syncFailed": false, "statuses": [], "tags": []]
            let payload = try JSONDecoder().decode(OutlinerRowPayload.self, from: JSONSerialization.data(withJSONObject: json))
            row.update(payload, emit: { name, _, values in
                if name == "edit", case let .int(offset) = values["caret-utf16-offset"] { offsets.append(offset) }
            }, onOpenLink: { opened.append($0) })
            row.layoutIfNeeded()
            return row.subviews.compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "outliner.block-action.body" }!
        }
        func point(_ label: UILabel, at offset: Int) -> CGPoint {
            let storage = NSTextStorage(attributedString: label.attributedText!)
            storage.addAttribute(.font, value: label.font as Any, range: NSRange(location: 0, length: storage.length))
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let glyph = manager.glyphIndexForCharacter(at: offset)
            let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let inset = OutlinerNativeTextLayoutPolicy.verticalInset(fontLineHeight: label.font.lineHeight,
                minimumLineHeight: OutlinerLayoutMetrics.titleLineHeight)
            return CGPoint(x: rect.minX + 0.01, y: rect.midY + floor(inset * label.contentScaleFactor) / label.contentScaleFactor)
        }
        for (text, caret) in [("Hello world", 0), ("Hello world", 3), ("Hello 👋 world", 9),
                              ("A wrapped block with several words that fill more than one line on a phone.", 45)] {
            let label = try update(text)
            row.activateTitle(at: point(label, at: caret))
            guard offsets.last == caret else { throw failure("A tap must retain UTF16 position \(caret), received \(String(describing: offsets.last))") }
        }
        let label = try update("Hello", markup: [["type": "text", "text": "Hello"]])
        row.activateTitle(at: CGPoint(x: label.bounds.maxX - 1, y: label.font.lineHeight / 2))
        guard offsets.last == 5 else { throw failure("Trailing whitespace must select the end of its line") }
        let linked = try update("[Docs](https://example.com) after", markup: [
            ["type": "link", "url": "https://example.com", "children": [["type": "text", "text": "Docs"]]],
            ["type": "text", "text": " after"]])
        let count = offsets.count
        row.activateTitle(at: point(linked, at: 1))
        guard opened.count == 1, offsets.count == count else { throw failure("Link taps must keep opening their destination") }
        row.activateTitle(at: point(linked, at: 6))
        guard offsets.last == 29 else { throw failure("Text after a link must map to the source title position") }
        let uuid = "10000000-0000-4000-8000-000000000006"
        let referenceNodes = try JSONDecoder().decode([LogseqMarkupNode].self, from: JSONSerialization.data(withJSONObject: [
            ["type": "nodeReference", "uuid": uuid, "title": "Project"],
            ["type": "text", "text": " after"]]))
        guard OutlinerTapCaret.sourceOffset(13, title: "[[" + uuid + "]] after", nodes: referenceNodes) == 42 else {
            throw failure("Text after a resolved reference must retain its stored source position")
        }
        let heading = try JSONDecoder().decode(OutlinerRowPayload.self, from: JSONSerialization.data(withJSONObject: [
            "uuid": "heading", "title": "Hello world", "markup": [["type": "emphasis", "style": "heading-1",
                "children": [["type": "text", "text": "Hello world"]]]],
            "depth": 0, "hasChildren": false, "collapsed": false, "isAsset": false, "assetType": "", "localPath": "",
            "youtubeURL": "", "completed": false, "selected": false, "opensAsPage": false, "journalBullet": false,
            "syncFailed": false, "statuses": [], "tags": []]))
        let headingFont = UIFont.preferredFont(forTextStyle: .title1)
        let headingX = ("Hel" as NSString).size(withAttributes: [.font: headingFont]).width
        guard OutlinerTapCaret.offset(at: CGPoint(x: headingX + 0.01, y: headingFont.lineHeight / 2), width: 260,
            title: heading.title, nodes: heading.markup) == 3 else { throw failure("Heading taps must use the displayed font metrics") }
        let effects = TapEffects()
        effects.snapshot = { caret in
            var result: [String: Any] = ["selectedGraphId": "demo", "graphName": "Demo", "outlinerRows": [
                ["depth": 0, "block": ["uuid": "body", "title": "Hello world", "pageId": "page"]]]]
            if let caret { result["outlinerState"] = ["editing": ["uuid": "body", "title": "Hello world", "caretUTF16Offset": caret]] }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(effects.snapshot(nil))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        for _ in 0..<100 {
            if views(window).contains(where: { $0 is OutlinerTextRowView }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        window.layoutIfNeeded()
        let mounted = views(window).compactMap { $0 as? OutlinerTextRowView }.first!
        let mountedLabel = views(mounted).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "outliner.block-action.body" }!
        mounted.activateTitle(at: point(mountedLabel, at: 3))
        for _ in 0..<100 {
            if views(window).compactMap({ $0 as? UITextView }).contains(where: { $0.isFirstResponder && $0.selectedRange.location == 3 }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard effects.caret == 3, views(window).compactMap({ $0 as? UITextView }).contains(where: {
            $0.isFirstResponder && $0.selectedRange == NSRange(location: 3, length: 0)
        }) else { throw failure("The real renderer, native bridge and editor must preserve the tapped position") }
        print("PASS: block taps retain plain, Unicode, wrapped and markdown source positions")
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "BlockTapCaret", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
