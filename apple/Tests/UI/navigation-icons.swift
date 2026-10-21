import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class NavigationIconEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct NavigationIconsCheck {
    @MainActor static func main() async throws {
        let bundle = Bundle(url: Bundle.main.bundleURL.appendingPathComponent("logseq_Logseq.bundle"))!
        for (key, source) in LGIconPolicy.icons {
            guard case let .assetName(name) = source else { continue }
            guard let image = UIImage(named: name, in: bundle, compatibleWith: nil) else {
                throw failure("Missing navigation asset: \(key)")
            }
            var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
            let visible = pixels.withUnsafeMutableBytes { bytes -> Bool in
                let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                    bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                UIGraphicsPushContext(context)
                image.draw(in: CGRect(x: 0, y: 0, width: 32, height: 32))
                UIGraphicsPopContext()
                return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 }
            }
            guard visible else { throw failure("Navigation asset renders transparent: \(key) (\(name))") }
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: NavigationIconEffects())
        try runtime.applyCoreResponse(#"{"ok":true,"result":{"selectedGraphId":"navigation-icons","graphName":"Navigation icons","syncConnected":true,"selectedPage":{"uuid":"page","title":"Navigation icons"},"outlinerRows":[{"depth":0,"block":{"uuid":"block","title":"Visible menu and sync icons, adaptive search color","pageId":"page"}}]}}"#)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        try await Task.sleep(for: .milliseconds(700))
        for (style, name) in [(UIUserInterfaceStyle.light, "navigation-icons-light.png"), (.dark, "navigation-icons-dark.png")] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(400))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(name))
            let area = CGRect(x: (window.bounds.width - 83) * image.scale,
                y: (window.bounds.height - 100) * image.scale, width: 70 * image.scale, height: 90 * image.scale)
            let crop = image.cgImage!.cropping(to: area)!
            var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            let blue = pixels.withUnsafeMutableBytes { bytes -> Int in
                let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                var count = 0
                for index in stride(from: 0, to: bytes.count, by: 4) {
                    let red = Int(bytes[index])
                    let green = Int(bytes[index + 1])
                    let blue = Int(bytes[index + 2])
                    if blue > red + 20 && blue > green + 20 && bytes[index + 3] > 100 { count += 1 }
                }
                return count
            }
            guard blue == 0 else { throw failure("Search must use adaptive foreground instead of blue (\\(blue) blue pixels, \\(name))") }
        }
        print("PASS: every navigation asset contains visible pixels; menu and sync icons render, and search uses adaptive foreground")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "NavigationIcons", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
