import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@main struct ImageCompressionChecks {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = fixture(width: 4032, height: 3024)
        let original = encode(image, type: .jpeg, quality: 1)
        let result = LGImageCompression.prepare(original, title: "Photo.jpg", contentType: "image/jpeg")
        check(result.data.count < original.count * 9 / 10, "large JPEG must save at least 10%")
        let decoded = decode(result.data)
        check(decoded.width == 2560 && decoded.height == 1920, "photos must keep aspect ratio at 2560px")
        let reference = thumbnail(original, maxSize: 2560)
        let psnr = peakSignalToNoise(reference, decoded)
        check(psnr > 35, "JPEG quality must exceed 35dB PSNR, got \(psnr)")
        try original.write(to: directory.appendingPathComponent("photo-before.jpg"))
        try result.data.write(to: directory.appendingPathComponent("photo-after.jpg"))
        print("JPEG: \(original.count) -> \(result.data.count) bytes; 4032x3024 -> 2560x1920; PSNR \(psnr) dB")
        let landscape = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.wallpapers/Sonoma Horizon/Sonoma Horizon.heic")
        if let data = try? Data(contentsOf: landscape) {
            let input = encode(thumbnail(data, maxSize: 4032), type: .jpeg, quality: 1)
            let output = LGImageCompression.prepare(input, title: "Landscape.jpg", contentType: "image/jpeg")
            let quality = peakSignalToNoise(thumbnail(input, maxSize: 2560), decode(output.data))
            check(quality > 35 && output.data.count < input.count * 9 / 10, "landscape photo quality and savings")
            try input.write(to: directory.appendingPathComponent("landscape-before.jpg"))
            try output.data.write(to: directory.appendingPathComponent("landscape-after.jpg"))
            print("Landscape: \(input.count) -> \(output.data.count) bytes; PSNR \(quality) dB")
        }

        for orientation in 1...8 {
            let input = encode(image, type: .jpeg, quality: 1, orientation: orientation)
            let output = LGImageCompression.prepare(input, title: "Rotated.jpeg", contentType: "image/jpeg")
            let expected = thumbnail(input, maxSize: 2560)
            let actual = decode(output.data)
            check(actual.width == expected.width && actual.height == expected.height, "orientation \(orientation) dimensions")
            check(peakSignalToNoise(expected, actual) > 35, "orientation \(orientation) pixels must be upright")
        }
        let small = encode(fixture(width: 160, height: 120), type: .jpeg, quality: 0.9)
        unchanged(small, title: "Small.jpg", mime: "image/jpeg")
        let lowQuality = encode(fixture(width: 2560, height: 1920), type: .jpeg, quality: 0.15)
        unchanged(lowQuality, title: "Optimized.jpg", mime: "image/jpeg")

        // Text, fine lines and alpha must remain pixel-exact, even above the photo size limit.
        let screenshot = encode(textFixture(), type: .png)
        unchanged(screenshot, title: "Screenshot.png", mime: "image/png")
        try screenshot.write(to: directory.appendingPathComponent("screenshot.png"))
        let transparent = encode(fixture(width: 1200, height: 900, alpha: true), type: .png)
        unchanged(transparent, title: "Transparent.png", mime: "image/png")
        let animated = NSMutableData()
        let destination = CGImageDestinationCreateWithData(animated, UTType.gif.identifier as CFString, 2, nil)!
        CGImageDestinationAddImage(destination, fixture(width: 64, height: 48), nil)
        CGImageDestinationAddImage(destination, fixture(width: 48, height: 64), nil)
        check(CGImageDestinationFinalize(destination), "GIF fixture encoding")
        unchanged(animated as Data, title: "Animation.gif", mime: "image/gif")
        let apng = NSMutableData()
        let apngDestination = CGImageDestinationCreateWithData(apng, UTType.png.identifier as CFString, 2, nil)!
        CGImageDestinationAddImage(apngDestination, fixture(width: 64, height: 48), nil)
        CGImageDestinationAddImage(apngDestination, fixture(width: 64, height: 48, alpha: true), nil)
        check(CGImageDestinationFinalize(apngDestination), "APNG fixture encoding")
        unchanged(apng as Data, title: "Animation.png", mime: "image/png")
        if let heic = try? Data(contentsOf: URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")) {
            unchanged(heic, title: "Photo.heic", mime: "image/heic")
        }
        unchanged(Data("%PDF-1.4\n%%EOF".utf8), title: "Document.pdf", mime: "application/pdf")
        unchanged(Data("# Notes\n中文".utf8), title: "Notes.md", mime: "text/markdown")
        unchanged(Data([0xFF, 0xD8, 0xFF]), title: "Corrupt.jpg", mime: "image/jpeg")
        unchanged(Data(), title: "Empty.jpg", mime: "image/jpeg")
        let mismatch = LGImageCompression.prepare(small, title: "Picker.heic", contentType: "image/heic")
        check(mismatch.title == "Picker.jpg" && mismatch.contentType == "image/jpeg", "detected type must match filename and MIME")
        let tall = encode(fixture(width: 1000, height: 4000), type: .jpeg, quality: 1)
        unchanged(tall, title: "Long scan.jpg", mime: "image/jpeg")
        let first = try await LGAssetImporter.persist(data: small, title: "Same.jpg")
        let second = try await LGAssetImporter.persist(data: original, title: "Same.jpg")
        check(first.path != second.path, "same-name imports must not overwrite a pending upload")
        try FileManager.default.removeItem(atPath: first.path)
        try FileManager.default.removeItem(atPath: second.path)
        // Exercise production persistence and App Group staging, including their hashes.
        for (name, data, mime) in [("Photo.jpg", original, "image/jpeg"),
                                   ("Screenshot.png", screenshot, "image/png"),
                                   ("Notes.md", Data("# Notes".utf8), "text/markdown")] {
            let expected = LGImageCompression.prepare(data, title: name, contentType: mime)
            let source = directory.appendingPathComponent(name)
            try data.write(to: source)
            let fromFile = try await LGAssetImporter.persist(source)
            let fromData = try await LGAssetImporter.persist(data: data, title: "Data-" + name)
            for imported in [fromFile, fromData] {
                let actual = try Data(contentsOf: URL(fileURLWithPath: imported.path))
                check(actual == expected.data && imported.size == actual.count,
                      "\(name) file and data persistence must use the prepared bytes")
                check(imported.checksum == SHA256.hash(data: actual).map { String(format: "%02x", $0) }.joined(),
                      "\(name) checksum must describe stored bytes")
                try FileManager.default.removeItem(atPath: imported.path)
            }
            let shared = directory.appendingPathComponent("Shared", isDirectory: true)
            let staged = try SharedCaptureAssetStager.stage(sourceURL: source, contentType: mime, sharedDirectory: shared)
            check(staged.size == expected.data.count && staged.assetType == mime, "staged metadata must describe prepared bytes")
            let imported = try SharedCaptureAssetImporter.importAsset(staged, sharedDirectory: shared,
                documentsDirectory: directory.appendingPathComponent("Documents", isDirectory: true))
            let importedData = try Data(contentsOf: directory.appendingPathComponent("Documents/" + imported.localPath))
            check(importedData == expected.data,
                  "App Group import must validate the compressed checksum")
        }
        print("PASS: 8 orientations, small/optimized JPEG, lossless text/alpha PNG, animation, HEIC, non-images, invalid data, metadata")
    }

    static func unchanged(_ data: Data, title: String, mime: String) {
        let result = LGImageCompression.prepare(data, title: title, contentType: mime)
        check(result.data == data && result.title == title && result.contentType == mime, "\(title) must remain byte-identical")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func fixture(width: Int, height: Int, alpha: Bool = false) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 42
        for y in 0..<height {
            for x in 0..<width {
                seed = 1664525 &* seed &+ 1013904223
                let noise = Int(seed >> 28)
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(min(255, x * 220 / width + noise))
                bytes[offset + 1] = UInt8(min(255, y * 220 / height + noise))
                bytes[offset + 2] = UInt8(min(255, (x + y) * 220 / (width + height) + noise))
                if alpha { bytes[offset + 3] = UInt8(x * 255 / width) }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    static func textFixture() -> CGImage {
        let context = CGContext(data: nil, width: 1440, height: 3200, bitsPerComponent: 8,
            bytesPerRow: 1440 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1440, height: 3200))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for y in stride(from: 20, to: 3150, by: 42) {
            ("Logseq 图片压缩 · Small text 0123456789" as NSString).draw(at: NSPoint(x: 24, y: y),
                withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double = 1, orientation: Int = 1) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: orientation] as CFDictionary)
        check(CGImageDestinationFinalize(destination), "fixture encoding")
        return data as Data
    }

    static func decode(_ data: Data) -> CGImage {
        CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
    }

    static func thumbnail(_ data: Data, maxSize: Int) -> CGImage {
        CGImageSourceCreateThumbnailAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0,
            [kCGImageSourceCreateThumbnailFromImageAlways: true,
             kCGImageSourceCreateThumbnailWithTransform: true,
             kCGImageSourceThumbnailMaxPixelSize: maxSize] as CFDictionary)!
    }

    static func peakSignalToNoise(_ lhs: CGImage, _ rhs: CGImage) -> Double {
        guard lhs.width == rhs.width && lhs.height == rhs.height else { return 0 }
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &bytes, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return bytes
        }
        let a = pixels(lhs), b = pixels(rhs)
        var squaredError = 0.0
        for offset in stride(from: 0, to: a.count, by: 4) {
            for channel in 0..<3 {
                let delta = Double(a[offset + channel]) - Double(b[offset + channel])
                squaredError += delta * delta
            }
        }
        return squaredError == 0 ? .infinity : 10 * log10(255 * 255 / (squaredError / Double(lhs.width * lhs.height * 3)))
    }
}
