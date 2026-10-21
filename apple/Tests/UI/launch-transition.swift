import SwiftUI
import UIKit
@testable import Logseq

@main struct LaunchTransitionCheck {
    @MainActor static func main() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let button = UIButton(type: .system)
        button.setTitle("Ready to edit", for: .normal)
        button.frame = CGRect(x: 20, y: 150, width: 220, height: 50)
        var presses = 0
        button.addAction(UIAction { _ in presses += 1 }, for: .touchUpInside)
        controller.view.addSubview(button)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(100))
            controller.view.backgroundColor = UIColor(LogseqThemePolicy.palette(
                mode: .system, systemIsDark: style == .dark).background)
            let transition = LogseqLaunchTransition()
            transition.show(in: window)
            guard let cover = window.subviews.first(where: { $0.accessibilityIdentifier == "launch.transition" }) else {
                throw failure("The first frame must continue the system launch logo")
            }
            guard cover.frame == window.bounds, !cover.isUserInteractionEnabled,
                  cover.accessibilityElementsHidden else {
                throw failure("The launch cover must fill the window without intercepting input or VoiceOver")
            }
            guard let logo = cover.subviews.compactMap({ $0 as? UIImageView }).first,
                  let image = logo.image, image.size == CGSize(width: 128, height: 128) else {
                throw failure("The launch logo must use the same 128 pt asset as the system screen; actual: \(String(describing: cover.subviews.compactMap { ($0 as? UIImageView)?.image?.size }.first))")
            }
            let rendition = image.imageAsset?.image(with: cover.traitCollection) ?? image
            let rendered = UIGraphicsImageRenderer(size: rendition.size).image { _ in
                rendition.draw(at: .zero)
            }
            let pixel = rendered.cgImage!.cropping(to: CGRect(
                x: rendered.scale * 64, y: rendered.scale * 80, width: 1, height: 1))!
            var rgba = [UInt8](repeating: 0, count: 4)
            rgba.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            if style == .light {
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                UIColor(LogseqThemePolicy.light.secondaryText).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                guard rgba[3] > 240,
                      abs(Int(rgba[0]) - Int((red * 255).rounded())) <= 2,
                      abs(Int(rgba[1]) - Int((green * 255).rounded())) <= 2,
                      abs(Int(rgba[2]) - Int((blue * 255).rounded())) <= 2 else {
                    throw failure("Light appearance must use the softer theme gray logo: \(rgba)")
                }
            } else {
                guard rgba[3] > 240, Int(rgba[1]) > Int(rgba[0]) + 30, Int(rgba[2]) > Int(rgba[0]) + 30 else {
                    throw failure("Dark appearance must retain the cyan Logseq logo: \(rgba)")
                }
            }
            let expected = UIColor(LogseqThemePolicy.palette(mode: .system, systemIsDark: style == .dark).background)
            guard let background = cover.backgroundColor else { throw failure("Missing launch background") }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
            background.resolvedColor(with: cover.traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
            expected.getRed(&er, green: &eg, blue: &eb, alpha: &ea)
            guard abs(r-er) < 0.001, abs(g-eg) < 0.001, abs(b-eb) < 0.001 else {
                throw failure("Launch background mismatch: style=\(style.rawValue), coverStyle=\(cover.traitCollection.userInterfaceStyle.rawValue), actual=\(r),\(g),\(b), expected=\(er),\(eg),\(eb)")
            }
            window.layoutIfNeeded()
            let snapshot = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
                window.layer.render(in: context.cgContext)
            }
            let suffix = style == .dark ? "dark" : "light"
            try snapshot.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("launch-logo-\(suffix).png"))
            transition.finish(reduceMotion: false)
            guard cover.alpha == 0 else { throw failure("Readiness must start the fade immediately, without a minimum display time") }
            let point = button.convert(CGPoint(x: 100, y: 20), to: window)
            guard window.hitTest(point, with: nil) === button else { throw failure("Content must remain interactive during the fade") }
            button.sendActions(for: .touchUpInside)
            guard presses > 0 else { throw failure("The fade must not gate editing") }
            transition.finish(reduceMotion: false)
            try await Task.sleep(for: .milliseconds(250))
            guard cover.superview == nil else { throw failure("The cover must be removed when the short fade finishes") }
            transition.show(in: window)
            guard !window.subviews.contains(where: { $0.accessibilityIdentifier == "launch.transition" }) else {
                throw failure("Returning to an already launched app must not replay the logo")
            }
        }
        let reduced = LogseqLaunchTransition()
        reduced.show(in: window)
        reduced.finish(reduceMotion: true)
        guard !window.subviews.contains(where: { $0.accessibilityIdentifier == "launch.transition" }) else {
            throw failure("Reduce Motion must remove the launch cover synchronously")
        }
        let alreadyReady = LogseqLaunchTransition()
        alreadyReady.finish(reduceMotion: false)
        alreadyReady.show(in: window)
        guard !window.subviews.contains(where: { $0.accessibilityIdentifier == "launch.transition" }) else {
            throw failure("A late window attachment must never cover content that is already ready")
        }
        print("PASS: adaptive system-logo continuity, immediate readiness, interactive content, reduced motion, and no warm-start replay")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "LaunchTransition", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
