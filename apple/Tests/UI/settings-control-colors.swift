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
        try backend.performPress(node: find("button.sidebar"))
        try backend.performPress(node: find("button.sidebar.settings"))
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
            guard recognition.results?.contains(where: { $0.topCandidates(1).first?.string == "Date format" }) != true else {
                throw failure("Date format must not appear in settings")
            }
            let spell = try labelRect("Spell check")
            let correction = try labelRect("Auto-correction")
            guard abs(spell.minX - correction.minX) * window.bounds.width <= 3 else {
                throw failure("Native editor settings must remain aligned")
            }
            func matchingPixels(in rect: CGRect, where matches: (Int, Int, Int) -> Bool) -> Int {
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
                        if matches(r, g, b) { count += 1 }
                    }
                    return count
                }
            }
            let dark = style == .dark
            let background = dark ? (0, 45, 56) : (242, 242, 247)
            let gutter = CGRect(x: 7, y: (1 - spell.midY) * window.bounds.height - 4, width: 5, height: 8)
            guard matchingPixels(in: gutter, where: { r, g, b in
                abs(r - background.0) <= 3 && abs(g - background.1) <= 3 && abs(b - background.2) <= 3
            }) > 20 else { throw failure("Settings sheet must use the themed canvas behind its groups") }
            let accent = (3, 125, 186)
            func usesAccent(_ r: Int, _ g: Int, _ b: Int) -> Bool {
                abs(r - accent.0) <= 12 && abs(g - accent.1) <= 12 && abs(b - accent.2) <= 12
            }
            for control in switches {
                let rect = control.convert(control.bounds, to: window)
                guard matchingPixels(in: rect, where: usesAccent) > 100 else { throw failure("Native settings switches must use the sheet accent") }
            }
            for identifier in ["picker.settings.appearance", "picker.settings.language"] {
                guard let rect = frames[try find(identifier)] else { throw failure("Missing picker frame: " + identifier) }
                guard matchingPixels(in: rect, where: usesAccent) == 0 else { throw failure("Picker value must use text color: " + identifier) }
            }
        }
        guard backend.rootIDs.flatMap(ids).allSatisfy({
            backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue != "picker.settings.date-format"
        }), effects.formats.isEmpty else {
            throw failure("Hidden date format controls must not retain interactive nodes or emit mutations")
        }
        let settingsID = try find("sheet.settings")
        try backend.performPress(node: find("link.settings.tabs"))
        for _ in 0..<25 {
            if backend.modalPresentation.nestedSheets[settingsID] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let tabsID = try find("sheet.settings.tabs")
        guard backend.modalPresentation.nestedSheets[settingsID]?.id == tabsID else {
            throw failure("Tabs must present above Settings")
        }
        try backend.performDismiss(node: tabsID)
        for _ in 0..<25 {
            if backend.modalPresentation.nestedSheets.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard backend.modalPresentation.item?.id == settingsID, backend.modalPresentation.nestedSheets.isEmpty else {
            throw failure("Dismissing Tabs must retain Settings")
        }
        print("PASS: Settings uses the graph background, one accent, and retains nested presentation")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "SettingsControlColors", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
