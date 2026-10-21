import SwiftUI
import UIKit
import CoreText
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class IconEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct NodeIconsCheck {
    @MainActor static func main() async throws {
        let filled = try JSONDecoder().decode(NodeIconPayload.self, from: Data(##"{"type":"tabler-icon","id":"HeartFilled","color":"#5e69d2"}"##.utf8))
        let filledGlyph = NodeIconAssets.glyph(filled)
        guard let family = filledGlyph.family, let font = UIFont(name: family, size: 20) else { throw failure("Filled font is missing") }
        var characters = Array(filledGlyph.text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count), glyphs.allSatisfy({ $0 != 0 }) else {
            throw failure("The filled Tabler font must supply HeartFilled without colliding with the outline font")
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: IconEffects())
        func response(icons: Bool) throws -> String {
            let descriptors: [String: Any] = icons ? [
                "page": ["type": "tabler-icon", "id": "Rocket", "color": "#fb434c"],
                "plain": ["type": "emoji", "id": "wave", "skin": 5],
                "rich": ["type": "tabler-icon", "id": "HeartFilled", "color": "#5e69d2"]
            ] : ["page": NSNull(), "plain": NSNull(), "rich": NSNull()]
            let rows: [[String: Any]] = [
                ["depth": 0, "block": ["uuid": "plain", "title": "Native text row", "pageId": "page"]],
                ["depth": 1, "block": ["uuid": "rich", "title": "**Rich** text row", "pageId": "page", "markup": [["type": "emphasis", "style": "bold", "children": [["type": "text", "text": "Rich"]]], ["type": "text", "text": " text row"]]]]
            ]
            let result: [String: Any] = ["selectedGraphId": "icons", "graphName": "Existing graph icons",
                "selectedPage": ["uuid": "page", "title": "Project icons"],
                "favorites": [["uuid": "page", "title": "Project icons"], ["uuid": "plain", "title": "Saved node"]],
                "recentPages": [["uuid": "rich", "title": "Recent node"]],
                "nodeIcons": descriptors, "outlinerRows": rows, "outlinerState": ["selectedBlockIds": []]]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        try runtime.applyCoreResponse(response(icons: true))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        try await Task.sleep(for: .milliseconds(900))
        let backend = runtime.renderer.backend
        func ids(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(ids)
        }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        let colored = views(window).compactMap { $0 as? UIButton }.filter {
            $0.accessibilityIdentifier?.hasPrefix("button.outliner.zoom.") == true
        }
        guard colored.count >= 1, colored.allSatisfy({ $0.image(for: .normal)?.renderingMode == .alwaysOriginal }) else {
            throw failure("Existing emoji and colored Tabler icons must render in both native text and rich block rows")
        }
        func screenshot(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(name))
        }
        try screenshot("page-node-icons.png")
        let drawer = backend.rootIDs.flatMap(ids).first { backend.model(id: $0)?.kind == .drawer }!
        try backend.performToggle(node: drawer, checked: true)
        try await Task.sleep(for: .milliseconds(500))
        try screenshot("favorite-recent-icons.png")
        try backend.performToggle(node: drawer, checked: false)
        try runtime.applyCoreResponse(response(icons: false))
        await runtime.drainEffectsForTesting()
        try await Task.sleep(for: .milliseconds(500))
        let reset = views(window).compactMap { $0 as? UIButton }.filter { $0.accessibilityIdentifier?.hasPrefix("button.outliner.zoom.") == true }
        guard reset.allSatisfy({ $0.image(for: .normal)?.renderingMode != .alwaysOriginal }) else {
            throw failure("Removing an icon must reset reused native rows to the ordinary bullet")
        }
        let journal: [String: Any] = ["ok": true, "result": ["selectedGraphId": "icons", "graphName": "Existing graph icons",
            "nodeIcons": ["journal": ["type": "emoji", "id": "calendar"]],
            "outlinerRows": [["depth": 0, "block": ["uuid": "journal-block", "title": "Journal with an existing icon", "pageId": "journal", "journalTitle": "Oct 22nd, 2026", "journalDay": 20261022]]]]]
        try runtime.applyCoreResponse(String(decoding: JSONSerialization.data(withJSONObject: journal), as: UTF8.self))
        try await Task.sleep(for: .milliseconds(500))
        try screenshot("journal-icon.png")
        print("PASS: existing graph icons and colors render in page, favorites, recents, native text and rich rows; removing icons resets reused rows")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "NodeIcons", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
