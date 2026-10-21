import SwiftUI
import UIKit
@testable import Logseq

@MainActor private final class LinkColorEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct LinkColorParityCheck {
    @MainActor static func main() async throws {
        let rows: [[String: Any]] = [
            ["depth": 0, "block": ["uuid": "url", "title": "https://example.test/native", "markup": [["type": "link", "url": "https://example.test/native", "children": [["type": "text", "text": "https://example.test/native"]]]]]],
            ["depth": 0, "block": ["uuid": "mixed", "title": "Page reference and URL", "markup": [["type": "nodeReference", "uuid": "page", "title": "quick capture"], ["type": "text", "text": "  "], ["type": "link", "url": "https://example.test/mixed", "children": [["type": "text", "text": "mixed URL"]]]]]],
            ["depth": 0, "block": ["uuid": "tags", "title": "Inline and footer tags", "markup": [["type": "tagReference", "uuid": "card", "title": "Card"], ["type": "text", "text": "  same master palette"]], "tags": [["uuid": "project", "title": "Project"]]]],
            ["depth": 0, "block": ["uuid": "plain", "title": "Native row with a tag", "tags": [["uuid": "native-tag", "title": "Native tag"]]]]
        ]
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LinkColorEffects())
        let result: [String: Any] = ["ok": true, "result": ["selectedGraphId": "link-colors", "graphName": "Link colors",
            "selectedPage": ["uuid": "page", "title": "Master link colors"], "syncConnected": true, "outlinerRows": rows]]
        try runtime.applyCoreResponse(String(decoding: JSONSerialization.data(withJSONObject: result), as: UTF8.self))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        for (style, name, target) in [(UIUserInterfaceStyle.light, "link-colors-light.png", (27, 104, 152)), (.dark, "link-colors-dark.png", (155, 211, 212))] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(700))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(name))
            let cg = image.cgImage!
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let counts = pixels.withUnsafeMutableBytes { bytes -> (Int, Int) in
                let context = CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                var master = 0, systemBlue = 0
                for index in stride(from: 0, to: bytes.count, by: 4) {
                    let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
                    if abs(r - target.0) < 3 && abs(g - target.1) < 3 && abs(b - target.2) < 3 { master += 1 }
                    if abs(r) < 3 && abs(g - 122) < 3 && abs(b - 255) < 3 { systemBlue += 1 }
                }
                return (master, systemBlue)
            }
            guard counts.0 > 300, counts.1 == 0 else { throw failure("Expected master link palette without system blue: \(counts), \(name)") }
        }
        print("PASS: native URLs, rich URLs, page references, inline tags, and footer tags share master's light and dark colors")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "LinkColorParity", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
