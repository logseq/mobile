import SwiftUI
import UIKit
import Vision
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class SettingsColorEffects: LGEffectExecuting {
    var formats: [String] = []
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "set-journal-title-format" { formats.append(effect.text) }
        return LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct SettingsControlColorsCheck {
    @MainActor static func main() async throws {
        let effects = SettingsColorEffects()
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(#"{"ok":true,"result":{"selectedGraphId":"settings-colors","graphName":"Settings colors","journalTitleFormat":"yyyy-MM-dd","blocks":[],"outlinerRows":[]}}"#)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        try runtime.applyHostUpdate(kind: "restore-ui-session", payload: #"{"graphId":"settings-colors","destination":"journals","assets":[],"composerExpanded":false,"searchOpen":false,"query":"","appPath":[],"searchPath":[],"selectedPageId":null,"settingsOpen":true,"recentGraphIds":[]}"#)
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer).tint(LogseqThemePolicy.accent))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        func ids(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(ids)
        }
        func find(_ identifier: String) throws -> Int {
            guard let node = backend.rootIDs.flatMap(ids).first(where: { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier }) else { throw failure("Missing control: " + identifier) }
            return node
        }
        try await Task.sleep(for: .milliseconds(600))
        try await Task.sleep(for: .milliseconds(500))
        window.rootViewController?.presentedViewController?.sheetPresentationController?.selectedDetentIdentifier = .large
        try await Task.sleep(for: .milliseconds(500))
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        var switches: [UISwitch] = []
        for _ in 0..<30 {
            switches = views(window).compactMap { $0 as? UISwitch }
            if switches.count == 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if switches.count != 2 {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("settings-missing-switches.png"))
            throw failure("Expected both native editor switches, found \(switches.count)")
        }
        for identifier in ["switch.settings.spell-check", "switch.settings.auto-correction"] {
            let id = try find(identifier)
            if backend.model(id: id)?.isChecked != true { try backend.performToggle(node: id, checked: true) }
        }
        for (style, name) in [(UIUserInterfaceStyle.light, "settings-colors-light.png"), (.dark, "settings-colors-dark.png")] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(500))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(name))
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([recognition])
            func labelRect(_ text: String) throws -> CGRect {
                guard let observation = recognition.results?.first(where: { $0.topCandidates(1).first?.string == text }) else {
                    throw failure("Missing visible settings label: " + text)
                }
                return observation.boundingBox
            }
            let date = try labelRect("Date format")
            let spell = try labelRect("Spell check")
            let correction = try labelRect("Auto-correction")
            guard abs(date.minX - spell.minX) * window.bounds.width <= 3,
                  abs(date.midY - spell.midY) <= abs(spell.midY - correction.midY) + 3 / window.bounds.height else {
                throw failure("Date format must align with adjacent native editor settings and retain their row spacing")
            }
            func coloredPixels(in rect: CGRect, green: Bool) -> Int {
                let pixelRect = CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale,
                    width: rect.width * image.scale, height: rect.height * image.scale)
                guard let crop = image.cgImage!.cropping(to: pixelRect) else { return 0 }
                var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
                return pixels.withUnsafeMutableBytes { bytes -> Int in
                    let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                        bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                    var count = 0
                    for index in stride(from: 0, to: bytes.count, by: 4) {
                        let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
                        if green ? (g > r + 30 && g > b + 30) : (b > r + 30 && b > g + 20) { count += 1 }
                    }
                    return count
                }
            }
            for control in switches {
                let rect = control.convert(control.bounds, to: window)
                guard coloredPixels(in: rect, green: false) > 100 && coloredPixels(in: rect, green: true) == 0 else { throw failure("Native settings switches must use Logseq teal instead of system green") }
            }
            for identifier in ["picker.settings.appearance", "picker.settings.language", "picker.settings.date-format"] {
                guard let rect = frames[try find(identifier)] else { throw failure("Missing picker frame: " + identifier) }
                guard coloredPixels(in: rect, green: false) == 0 else { throw failure("Picker value must use text color: " + identifier) }
            }
        }
        let picker = try find("picker.settings.date-format")
        guard backend.model(id: try find("settings.date-format.option.yyyy-MM-dd"))?.isChecked == true,
              let frame = frames[picker], frame.width > 80, frame.maxX < window.bounds.maxX else {
            throw failure("The date format must show the current graph preference within the settings row")
        }
        let option = try find("settings.date-format.option.dd-MM-yyyy")
        try backend.performChange(node: option)
        for _ in 0..<100 {
            if !effects.formats.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard effects.formats.count == 1,
              let data = effects.formats[0].data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: String],
              payload["graphId"] == "settings-colors", payload["format"] == "dd-MM-yyyy" else {
            throw failure("A date-format choice must reach the graph-scoped mutation boundary")
        }
        try runtime.applyCoreResponse(#"{"ok":true,"result":{"selectedGraphId":"settings-colors","graphName":"Settings colors","journalTitleFormat":"dd-MM-yyyy","blocks":[],"outlinerRows":[]}}"#)
        try await Task.sleep(for: .milliseconds(200))
        guard backend.model(id: try find("settings.date-format.option.dd-MM-yyyy"))?.isChecked == true else {
            throw failure("The retained native picker must update from the confirmed graph preference")
        }
        print("PASS: native settings retain theme colors and expose graph-scoped date format choices with confirmed updates")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "SettingsControlColors", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
