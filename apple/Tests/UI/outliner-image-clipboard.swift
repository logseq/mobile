import SwiftUI
import UIKit
import ImageIO
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class ImageClipboardEffects: LGEffectExecuting {
    var pasted: [[String: Any]] = []
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "editor-outliner-event", let data = effect.text.data(using: .utf8),
           let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           fields["type"] as? String == "pasteContent" { pasted.append(fields) }
        return .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct OutlinerImageClipboardCheck {
    @MainActor static func main() async throws {
        let effects = ImageClipboardEffects()
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        // The target belongs to a previous day, not today's capture destination.
        try runtime.applyCoreResponse(#"{"ok":true,"result":{"selectedGraphId":"demo","graphName":"Demo","outlinerRows":[{"depth":0,"block":{"uuid":"yesterday-block","title":"Unsaved draft","pageId":"yesterday"}}],"outlinerState":{"editing":{"uuid":"yesterday-block","title":"Unsaved draft","caretUTF16Offset":13},"selectedBlockIds":[]}}}"#)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; runtime.stop() }
        try await Task.sleep(for: .milliseconds(600))
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        guard let editor = views(window).compactMap({ $0 as? UITextView }).first(where: { $0.isFirstResponder }) else { throw failure("Missing editor") }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600), format: format).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        let png = image.pngData()!, jpeg = image.jpegData(compressionQuality: 0.9)!
        let secondImage = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
            UIColor.systemPurple.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }.jpegData(compressionQuality: 0.9)!
        var errors: [String] = []
        for (name, items, expected) in [
            ("PNG", [["public.png": png]], 1),
            ("Photos JPEG", [["public.jpeg": jpeg]], 1),
            ("UIImage", [["com.apple.uikit.image": image]], 1),
            ("representations", [["public.png": png, "public.jpeg": jpeg]], 1),
            ("multiple items", [["public.png": png], ["public.jpeg": secondImage]], 2),
            ("corrupt image", [["public.png": Data("not an image".utf8)]], 0)
        ] as [(String, [[String: Any]], Int)] {
            let before = effects.pasted.count
            UIPasteboard.general.items = items
            if expected > 0 && !editor.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil) {
                errors.append("\(name): the native edit menu must enable Paste for images")
            }
            editor.paste(nil)
            try await Task.sleep(for: .milliseconds(800))
            let payloads = Array(effects.pasted.dropFirst(before))
            let assets = payloads.flatMap { $0["assets"] as? [[String: Any]] ?? [] }
            if assets.count != expected { errors.append("\(name): expected \(expected) imported images, got \(assets.count)"); continue }
            for payload in payloads where expected > 0 {
                if payload["uuid"] as? String != "yesterday-block" || payload["targetBlockId"] as? String != "yesterday-block"
                    || payload["beforeTitle"] as? String != "Unsaved draft" { errors.append("\(name): lost original target or draft") }
            }
            for (index, asset) in assets.enumerated() {
                guard let path = asset["localPath"] as? String,
                      let url = LocalAssetPath.resolve(path),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                      properties[kCGImagePropertyPixelWidth as String] as? Int == (index == 0 ? 800 : 400),
                      properties[kCGImagePropertyPixelHeight as String] as? Int == (index == 0 ? 600 : 300) else {
                    errors.append("\(name): image bytes were not imported with original dimensions"); continue
                }
            }
        }
        if editor.text != "Unsaved draft" { errors.append("Image paste changed the text draft") }
        guard errors.isEmpty else { throw failure(errors.joined(separator: "\n")) }
        print("PASS: native PNG, JPEG, UIImage, duplicate representations, ordered multiple items and corrupt clipboard images")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "OutlinerImageClipboard", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
