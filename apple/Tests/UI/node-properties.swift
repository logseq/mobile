import SwiftUI
import UIKit
import Vision
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class PropertyEffects: LGEffectExecuting {
    var edits: [String] = []
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "node-property" { edits.append(effect.text) }
        return LGEffectResolution(succeeded: false, message: "Value changed. Try again.", output: .discard)
    }
}

@main struct NodePropertiesCheck {
    @MainActor static func main() async throws {
        let effects = PropertyEffects()
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        let fixture = Bundle.main.url(forResource: "node-properties", withExtension: "json")!
        try runtime.applyCoreResponse(String(contentsOf: fixture, encoding: .utf8))
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
            backend.rootIDs.flatMap(descendants).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "NodeProperties", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        try await wait("Page properties must mount") { find("property.label.page.user.property/Summary") != nil }
        guard find("outliner.block.text-value") != nil, find("property.inline.page.user.property/Score") != nil else {
            throw NSError(domain: "NodeProperties", code: 2, userInfo: [NSLocalizedDescriptionKey: "Text must use block rendering and numbers must stay inline"])
        }
        guard find("property.label.page.user.property/Long") == nil,
              let expand = find("properties.expand.page") else {
            throw NSError(domain: "NodeProperties", code: 14, userInfo: [NSLocalizedDescriptionKey: "Properties show at most three rows before Expand"])
        }
        try backend.performPress(node: expand)
        try await wait("Expand reveals the remaining properties") { find("property.label.page.user.property/Long") != nil }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded()
            let labelFrames = ["Summary", "Score", "Ready"].compactMap { attr in
                find("property.label.page.user.property/\(attr)").flatMap { frames[$0] }
            }
            guard labelFrames.count == 3,
                  labelFrames.allSatisfy({ abs($0.minX - labelFrames[0].minX) <= 1 }) else {
                throw NSError(domain: "NodeProperties", code: 7, userInfo: [NSLocalizedDescriptionKey: "Property labels must share the same leading edge"])
            }
            func frame(_ prefix: String, _ attr: String) throws -> CGRect {
                guard let node = find("property.\(prefix).page.user.property/\(attr)"), let rect = frames[node] else {
                    throw NSError(domain: "NodeProperties", code: 8, userInfo: [NSLocalizedDescriptionKey: "Missing frame: \(prefix) \(attr)"])
                }
                return rect
            }
            for attr in ["Assignee", "Reproducible"] {
                let key = try frame("label", attr)
                let value = try frame("value", attr)
                guard key.height <= 21, abs(key.midY - value.midY) <= 7 else {
                    throw NSError(domain: "NodeProperties", code: 9, userInfo: [NSLocalizedDescriptionKey: "Ordinary property labels must stay on one line with slightly smaller type: \(attr) \(key)"])
                }
            }
            guard abs(try frame("value", "Score").minX - frame("value", "Assignee").minX) <= 1,
                  try frame("value", "Long").minY >= frame("label", "Long").maxY else {
                throw NSError(domain: "NodeProperties", code: 10, userInfo: [NSLocalizedDescriptionKey: "Short keys align in columns; long keys place their value below"])
            }
            guard find("breadcrumb.related-blocks") == nil else {
                throw NSError(domain: "NodeProperties", code: 11, userInfo: [NSLocalizedDescriptionKey: "Text properties must not show breadcrumbs"])
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("properties-\(style == .dark ? "dark" : "light").png"))
            for attr in ["Score", "Ready"] {
                guard let node = find("property.value.page.user.property/\(attr)"), let rect = frames[node],
                      let crop = image.cgImage?.cropping(to: CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale,
                        width: rect.width * image.scale, height: rect.height * image.scale)) else {
                    throw NSError(domain: "NodeProperties", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing property value frame"])
                }
                var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
                let blue = pixels.withUnsafeMutableBytes { bytes -> Int in
                    let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                        bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                    var count = 0
                    for index in stride(from: 0, to: bytes.count, by: 4) {
                        let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
                        if b > r + 30 && b > g + 20 { count += 1 }
                    }
                    return count
                }
                guard blue == 0 else {
                    throw NSError(domain: "NodeProperties", code: 6, userInfo: [NSLocalizedDescriptionKey: "Property \(attr) must use subdued color, including its checkbox"])
                }
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
            let observations = request.results ?? []
            if let score = observations.first(where: { $0.topCandidates(1).first?.string == "20" }),
               let assignee = observations.first(where: { $0.topCandidates(1).first?.string == "Tienson" }) {
                guard abs(score.boundingBox.minX - assignee.boundingBox.minX) * window.bounds.width <= 3 else {
                    throw NSError(domain: "NodeProperties", code: 16, userInfo: [NSLocalizedDescriptionKey: "The visible value text must align, not just its button frames"])
                }
            }
            let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            guard visible.contains("Summary"), visible.contains("Research"), visible.contains("20") else {
                throw NSError(domain: "NodeProperties", code: 3, userInfo: [NSLocalizedDescriptionKey: "Property values must be visible: \(visible)"])
            }
        }
        for (attr, time) in [("Due", false), ("Deadline", true)] {
            try backend.performPress(node: find("property.value.page.user.property/\(attr)")!)
            try await Task.sleep(for: .milliseconds(400))
            try await wait("A temporal property must open a native picker") {
                window.findDatePicker() != nil
            }
            guard let picker = window.findDatePicker(), picker.datePickerMode == (time ? .dateAndTime : .date) else {
                throw NSError(domain: "NodeProperties", code: 12, userInfo: [NSLocalizedDescriptionKey: "Incorrect native date picker mode"])
            }
            try await wait("The NLP date input must mount") { window.findNLPDateInput() != nil }
            let input = window.findNLPDateInput()!
            guard input.text?.isEmpty == true else {
                throw NSError(domain: "NodeProperties", code: 17, userInfo: [NSLocalizedDescriptionKey: "NLP inputs must open empty"])
            }
            let expression = time ? "January 1, 2000 at 3:20pm" : "January 1, 2000"
            input.text = expression
            input.sendActions(for: .editingChanged)
            let calendar = Calendar(identifier: .gregorian)
            let components: Set<Calendar.Component> = time ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            try await wait("NLP input must update the native date and time selection") {
                let selected = calendar.dateComponents(components, from: picker.date)
                return selected.year == 2000 && selected.month == 1 && selected.day == 1
                    && (!time || selected.hour == 15 && selected.minute == 20)
            }
            guard input.text == expression else {
                throw NSError(domain: "NodeProperties", code: 18, userInfo: [NSLocalizedDescriptionKey: "Preview must preserve the typed expression"])
            }
            let preview = picker.date
            for invalid in ["not a date", "in 10000 years"] {
                input.text = invalid
                input.sendActions(for: .editingChanged)
                try await Task.sleep(for: .milliseconds(150))
                guard picker.date == preview else {
                    throw NSError(domain: "NodeProperties", code: 19, userInfo: [NSLocalizedDescriptionKey: "Invalid or unrepresentable input must preserve the native selection"])
                }
            }
            let chosen = Date(timeIntervalSince1970: 1792719000)
            picker.setDate(chosen, animated: false)
            picker.sendActions(for: .valueChanged)
            try await Task.sleep(for: .milliseconds(150))
            let before = effects.edits.count
            try backend.performPress(node: find("view.edit.save.property.page.user.property/\(attr)")!)
            try await wait("Native date edits cross the bridge") { effects.edits.count > before }
            let payload = try JSONSerialization.jsonObject(with: Data(effects.edits.last!.utf8)) as! [String: Any]
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "yyyy-MM-dd"
            let expected = time ? "1792719000000" : format.string(from: chosen)
            guard payload["value"] as? String == expected else {
                throw NSError(domain: "NodeProperties", code: 15, userInfo: [NSLocalizedDescriptionKey: "Native date picker must submit its selected value: \(payload)"])
            }
            try backend.performPress(node: find("view.edit.cancel.property.page.user.property/\(attr)")!)
            try await Task.sleep(for: .milliseconds(350))
        }
        try backend.performPress(node: find("property.value.page.user.property/Skills")!)
        try await Task.sleep(for: .milliseconds(500))
        let options = (0..<3).compactMap { index in
            find("view.edit.option.property.page.user.property/Skills.skill-\(index)").flatMap { frames[$0] }
        }
        guard options.count == 3, options.allSatisfy({ $0.height <= 52 }),
              zip(options, options.dropFirst()).allSatisfy({ $1.minY - $0.maxY <= 18 }) else {
            throw NSError(domain: "NodeProperties", code: 13, userInfo: [NSLocalizedDescriptionKey: "Select options must use compact native rows: \(options)"])
        }
        try backend.performPress(node: find("view.edit.cancel.property.page.user.property/Skills")!)
        try await Task.sleep(for: .milliseconds(350))
        try backend.performToggle(node: find("property.value.page.user.property/Ready")!, checked: false)
        let editor = "property.page.user.property/Ready"
        try await wait("Typed edits cross the native bridge") { !effects.edits.isEmpty }
        try await wait("Property errors stay in the sheet") { find("view.action.error.\(editor)") != nil }
        guard find("property.label.page.user.property/Summary") != nil else {
            throw NSError(domain: "NodeProperties", code: 4, userInfo: [NSLocalizedDescriptionKey: "A failed edit must retain the property surface"])
        }
        print("PASS: native page properties, block text, inline values, themes, editor and local errors")
    }
}

private extension UIView {
    func findNLPDateInput() -> UITextField? {
        if let input = self as? UITextField, input.placeholder?.contains("tomorrow") == true { return input }
        return subviews.lazy.compactMap { $0.findNLPDateInput() }.first
    }

    func findDatePicker() -> UIDatePicker? {
        if let picker = self as? UIDatePicker { return picker }
        return subviews.lazy.compactMap { $0.findDatePicker() }.first
    }
}
