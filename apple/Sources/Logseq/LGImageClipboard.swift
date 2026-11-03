#if os(iOS)
import UIKit
import ImageIO
import UniformTypeIdentifiers

enum LGImageClipboard {
    struct Image: Sendable {
        let data: Data
        let title: String
    }

    @MainActor static func images() -> [Image] {
        // Each item may expose several encodings of the same photo. Preserve
        // item order, choosing one original representation per image.
        UIPasteboard.general.items.compactMap { item in
            let preferred = [UTType.png.identifier, UTType.jpeg.identifier]
            let types = preferred + item.keys.filter { !preferred.contains($0) }.sorted()
            for type in types where UTType(type)?.conforms(to: .image) == true {
                guard let data = item[type] as? Data,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetCount(source) > 0 else { continue }
                let actualType = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
                return Image(data: data, title: "Pasted image." + (actualType?.preferredFilenameExtension ?? "png"))
            }
            if let image = item.values.compactMap({ $0 as? UIImage }).first,
               let data = image.pngData() {
                return Image(data: data, title: "Pasted image.png")
            }
            return nil
        }
    }

    static func importImages(_ images: [Image]) async throws -> [LGStagedAssetPayload] {
        var assets: [LGStagedAssetPayload] = []
        do {
            for image in images {
                assets.append(LGStagedAssetPayload(try await LGAssetImporter.persist(data: image.data, title: image.title)))
            }
            return assets
        } catch {
            for asset in assets { try? FileManager.default.removeItem(atPath: asset.localPath) }
            throw error
        }
    }

    static func content(_ assets: [LGStagedAssetPayload], blockID: String, before: String, selection: NSRange) throws -> String {
        struct Content: Encodable {
            let assets: [LGStagedAssetPayload]
            let targetBlockId: String
            let beforeTitle: String
            let selectionStart: Int
            let selectionLength: Int
        }
        return String(decoding: try JSONEncoder().encode(Content(assets: assets, targetBlockId: blockID, beforeTitle: before,
            selectionStart: selection.location, selectionLength: selection.length)), as: UTF8.self)
    }
}
#endif
