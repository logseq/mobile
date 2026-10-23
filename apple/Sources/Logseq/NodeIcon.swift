import CoreText
import Foundation
import LUIAppleBackend
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct NodeIconPayload: Decodable, Hashable {
    let type: String
    let id: String
    let color: String?
    let skin: Int?

    var foreground: Color {
        guard let color, color.hasPrefix("#"), let bits = UInt64(color.dropFirst(), radix: 16),
              color.count == 7 || color.count == 9 else { return .primary }
        let rgb = color.count == 9 ? bits >> 8 : bits
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255,
                     opacity: color.count == 9 ? Double(bits & 255) / 255 : 1)
    }
}

enum NodeIconAssets {
    private struct Catalog: Decodable {
        struct Glyph: Decodable {
            let scalar: UInt32
            let filled: Bool
            init(from decoder: Decoder) throws {
                var values = try decoder.unkeyedContainer()
                scalar = try values.decode(UInt32.self)
                filled = try values.decode(Bool.self)
            }
        }
        let tabler: [String: Glyph]
        let emoji: [String: [String]]
    }
    private static let catalog: Catalog? = resource("node-icons", "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Catalog.self, from: $0) }
    private static func resource(_ name: String, _ type: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: type)
            ?? Bundle.module.url(forResource: name, withExtension: type, subdirectory: "NodeIcons")
    }
    private static let families: [Bool: String] = {
        var result: [Bool: String] = [:]
        for filled in [false, true] {
            guard let url = resource(filled ? "tabler-icons-filled" : "tabler-icons", "ttf"),
                  let provider = CGDataProvider(url: url as CFURL), let font = CGFont(provider),
                  let name = font.postScriptName else { continue }
            CTFontManagerRegisterGraphicsFont(font, nil)
            result[filled] = name as String
        }
        return result
    }()

    static func glyph(_ icon: NodeIconPayload) -> (text: String, family: String?) {
        if icon.type == "emoji" {
            if let skins = catalog?.emoji[icon.id.trimmingCharacters(in: CharacterSet(charactersIn: ":"))], !skins.isEmpty {
                return (skins[min(max((icon.skin ?? 1) - 1, 0), skins.count - 1)], nil)
            }
            return (icon.id.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) ? icon.id : "", nil)
        }
        let key = icon.id.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard let glyph = catalog?.tabler[key], let scalar = UnicodeScalar(glyph.scalar),
              let family = families[glyph.filled] else { return ("", nil) }
        return (String(scalar), family)
    }
}

struct NodeIconView: View {
    let icon: NodeIconPayload
    let size: CGFloat
    var muted: Bool = false
    var body: some View {
        let glyph = NodeIconAssets.glyph(icon)
        Text(verbatim: glyph.text)
            .font(glyph.family.map { .custom($0, size: size) } ?? .system(size: size))
            .foregroundStyle(muted ? .secondary : icon.foreground)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor enum NodeIconExtension {
    static let fingerprint = "lui-extension-v1|9:node-icon|profiles:android/kotlin,ios/swiftui|standard-children:0|children:|properties:4:size:int:required:none,5:muted:bool:required:none,7:payload:string:required:none|events:"
    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(LUIAppleExtension(identifier: "node-icon", fingerprint: fingerprint,
            acceptsStandardChildren: false,
            properties: [.init(name: "payload", kind: .string, isRequired: true), .init(name: "size", kind: .int, isRequired: true), .init(name: "muted", kind: .bool, isRequired: true)], events: []) { context in
            guard case let .string(encoded) = context.property("payload"),
                  let icon = try? JSONDecoder().decode(NodeIconPayload.self, from: Data(encoded.utf8)),
                  case let .int(size) = context.property("size"),
                  case let .bool(muted) = context.property("muted") else { return AnyView(EmptyView()) }
            return AnyView(NodeIconView(icon: icon, size: CGFloat(size), muted: muted))
        })
    }

    #if os(iOS)
    private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 512
        return cache
    }()
    static func image(_ icon: NodeIconPayload, size: CGFloat, traits: UITraitCollection) -> UIImage? {
        let glyph = NodeIconAssets.glyph(icon)
        guard !glyph.text.isEmpty else { return nil }
        let key = "\(icon)|\(size)|\(traits.userInterfaceStyle.rawValue)|\(traits.displayScale)" as NSString
        if let image = images.object(forKey: key) { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = traits.displayScale
        let font = glyph.family.flatMap { UIFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(icon.foreground).resolvedColor(with: traits)]
            let text = glyph.text as NSString
            let bounds = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2), withAttributes: attributes)
        }.withRenderingMode(.alwaysOriginal)
        images.setObject(image, forKey: key)
        return image
    }
    #endif
}
