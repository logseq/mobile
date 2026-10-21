import Foundation
import ImageIO
import UniformTypeIdentifiers

enum LGImageCompression {
    struct Asset {
        let data: Data
        let title: String
        let contentType: String
    }

    static func prepare(_ data: Data, title: String, contentType: String) -> Asset {
        let original = Asset(data: data, title: title, contentType: contentType)
        let declaredType = UTType(mimeType: contentType)
            ?? UTType(filenameExtension: contentType)
            ?? UTType(filenameExtension: (title as NSString).pathExtension)
        guard declaredType?.conforms(to: .image) == true,
              let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String) else { return original }

        // Pickers can deliver JPEG bytes for an advertised HEIC representation.
        let titleType = UTType(filenameExtension: (title as NSString).pathExtension)
        let correctedTitle = titleType == type ? title :
            (title as NSString).deletingPathExtension + "." + (type == .jpeg ? "jpg" : type.preferredFilenameExtension ?? "img")
        let asset = Asset(data: data, title: correctedTitle, contentType: type.preferredMIMEType ?? contentType)

        // PNG keeps screenshot text and alpha pixel-exact. Preserve HEIC, animation,
        // RAW and auxiliary images (including HDR gain maps) in their original format.
        guard type == .jpeg, data.count > 512 * 1024, CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 100_000_000,
              Double(max(width, height)) / Double(min(width, height)) <= 3,
              (properties[kCGImagePropertyDepth] as? Int ?? 8) <= 8 else { return asset }
        for auxiliaryType in [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeDepth,
                              kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypePortraitEffectsMatte] {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, auxiliaryType) != nil { return asset }
        }

        // Decode directly to the upload resolution instead of allocating a full photo.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(2560, max(width, height)),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { return asset }
        let compressed = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(compressed, UTType.jpeg.identifier as CFString, 1, nil)
        else { return asset }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyOrientation: 1
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination), compressed.length < data.count * 9 / 10 else { return asset }
        return Asset(data: compressed as Data, title: correctedTitle, contentType: "image/jpeg")
    }
}
