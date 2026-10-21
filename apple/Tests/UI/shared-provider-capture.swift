import UIKit
import UniformTypeIdentifiers
import ImageIO
import CryptoKit

@main struct SharedProviderCaptureCheck {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil,
                          NSStringFromClass(SharedProviderCaptureDelegate.self))
    }
}

@MainActor final class SharedProviderCaptureDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        Task { @MainActor in
            let result: String
            do { try await run(); result = "PASS: text, photos, screenshots, PDF and Markdown survive provider loading, queueing and import" }
            catch { result = "FAIL: \(error)" }
            let output = URL.documentsDirectory.appendingPathComponent("result.txt")
            try? result.write(to: output, atomically: true, encoding: .utf8)
        }
        return true
    }

    func run() async throws {
        let text = NSItemProvider(object: "Shared selected text 中文" as NSString)
        guard case .text("Shared selected text 中文") = await load(text) else {
            throw CheckError.failed("selected text did not load")
        }
        let textItem = SharedItem.text("Shared selected text 中文")
        guard ShareViewController.persist([textItem]) else { throw CheckError.failed("text queue write failed") }
        let inbox = SharedCaptureInbox(directory: SharedCaptureStorage.queueDirectory)
        guard inbox.pendingItems().first(where: { $0.id == textItem.id })?.captureText == "Shared selected text 中文" else {
            throw CheckError.failed("selected text was not persisted")
        }
        inbox.acknowledge(id: textItem.id)
        let raw = SharedItem(id: UUID().uuidString.lowercased(), kind: .payload,
            captureText: nil, captureAsset: nil,
            capturePayload: SharedPayload(text: "https://example.com", title: "Example", url: nil))
        guard ShareViewController.persist([raw]),
              let queuedRaw = inbox.pendingItems().first(where: { $0.id == raw.id }),
              queuedRaw.kind == .payload,
              queuedRaw.capturePayload?.text == "https://example.com",
              queuedRaw.capturePayload?.title == "Example",
              queuedRaw.captureText == nil else {
            throw CheckError.failed("raw share metadata did not survive the extension queue")
        }
        inbox.acknowledge(id: raw.id)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let photo = image.jpegData(compressionQuality: 0.8)!
        let screenshot = image.pngData()!
        let root = URL.documentsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, type, data) in [
            ("Photo.jpg", UTType.jpeg, photo),
            ("Screenshot.png", UTType.png, screenshot),
            ("Document.pdf", UTType.pdf, Data("%PDF-1.4\n%%EOF".utf8)),
            ("Notes.md", UTType(filenameExtension: "md")!, Data("# Heading\n中文 **note**".utf8))
        ] {
            for fileRepresentation in [false, true] {
                let provider = NSItemProvider()
                provider.suggestedName = name
                if fileRepresentation {
                    let source = root.appendingPathComponent(name)
                    try data.write(to: source)
                    provider.registerFileRepresentation(forTypeIdentifier: type.identifier,
                        fileOptions: [], visibility: .all) { finish in
                        finish(source, false, nil)
                        return nil
                    }
                } else {
                    provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { finish in
                        finish(data, nil)
                        return nil
                    }
                }
                guard case .asset(let item) = await load(provider), let asset = item.captureAsset else {
                    throw CheckError.failed("\(name) did not load from \(fileRepresentation ? "file" : "data")")
                }
                guard ShareViewController.persist([item]) else { throw CheckError.failed("queue write failed") }
                let inbox = SharedCaptureInbox(directory: SharedCaptureStorage.queueDirectory)
                guard let queued = inbox.pendingItems().first(where: { $0.id == item.id }),
                      let payload = queued.captureAsset else { throw CheckError.failed("queue payload missing") }
                let imported = try SharedCaptureAssetImporter.importAsset(payload,
                    sharedDirectory: SharedCaptureStorage.sharedDirectory, documentsDirectory: root)
                guard imported.title == asset.title, imported.size == data.count,
                      try Data(contentsOf: root.appendingPathComponent(imported.localPath)) == data else {
                    throw CheckError.failed("\(name) changed during import")
                }
                inbox.acknowledge(id: item.id)
                guard !inbox.pendingItems().contains(where: { $0.id == item.id }) else {
                    throw CheckError.failed("capture acknowledgement failed")
                }
            }
        }
        guard case .asset(let screenshotItem) = await load(NSItemProvider(object: image)),
              let screenshotAsset = screenshotItem.captureAsset else {
            throw CheckError.failed("UIImage-only screenshot did not load")
        }
        try FileManager.default.removeItem(at: SharedCaptureStorage.sharedDirectory
            .appendingPathComponent(screenshotAsset.stagedFileName))
        let rotated = UIImage(cgImage: image.cgImage!, scale: 1, orientation: .right)
        guard case .asset(let rotatedItem) = await load(NSItemProvider(object: rotated)),
              let rotatedAsset = rotatedItem.captureAsset else { throw CheckError.failed("rotated UIImage did not load") }
        let rotatedURL = SharedCaptureStorage.sharedDirectory.appendingPathComponent(rotatedAsset.stagedFileName)
        defer { try? FileManager.default.removeItem(at: rotatedURL) }
        let rotatedData = try Data(contentsOf: rotatedURL)
        let source = CGImageSourceCreateWithData(rotatedData as CFData, nil)!
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int
        // UIImage's provider serializes orientation in its representation.
        guard orientation == 6 else { throw CheckError.failed("UIImage orientation was lost: \(String(describing: orientation))") }
        let largeImage = UIGraphicsImageRenderer(size: CGSize(width: 4032, height: 3024), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }()).image { context in
            for x in stride(from: 0, to: 4032, by: 3) {
                UIColor(hue: CGFloat(x % 101) / 101, saturation: 0.8, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: x, y: 0, width: 3, height: 3024))
            }
        }
        let largePhoto = largeImage.jpegData(compressionQuality: 1)!
        for fileRepresentation in [false, true] {
            let provider = NSItemProvider()
            provider.suggestedName = "Large.jpg"
            if fileRepresentation {
                let url = root.appendingPathComponent("Large.jpg")
                try largePhoto.write(to: url)
                provider.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier,
                    fileOptions: [], visibility: .all) { finish in finish(url, false, nil); return nil }
            } else {
                provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) {
                    finish in finish(largePhoto, nil); return nil
                }
            }
            guard case .asset(let item) = await load(provider), let asset = item.captureAsset else {
                throw CheckError.failed("large photo provider failed")
            }
            let staged = SharedCaptureStorage.sharedDirectory.appendingPathComponent(asset.stagedFileName)
            let compressed = try Data(contentsOf: staged)
            guard compressed.count < largePhoto.count * 9 / 10, asset.size == compressed.count,
                  asset.checksum == SHA256.hash(data: compressed).map({ String(format: "%02x", $0) }).joined() else {
                throw CheckError.failed("large photo size/checksum did not reflect compression")
            }
            let imported = try SharedCaptureAssetImporter.importAsset(
                SharedCaptureAsset(title: asset.title, assetType: asset.assetType, size: asset.size,
                    checksum: asset.checksum, stagedFileName: asset.stagedFileName),
                sharedDirectory: SharedCaptureStorage.sharedDirectory, documentsDirectory: root)
            guard imported.size == compressed.count else { throw CheckError.failed("compressed shared photo failed import") }
        }
        let fileURL = root.appendingPathComponent("File URL.md")
        let markdown = Data("# File URL Markdown".utf8)
        try markdown.write(to: fileURL)
        let fileProvider = NSItemProvider()
        fileProvider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { finish in
            finish(fileURL.dataRepresentation, nil)
            return nil
        }
        guard case .asset(let fileItem) = await load(fileProvider), let asset = fileItem.captureAsset else {
            throw CheckError.failed("file URL was not imported as a document")
        }
        let staged = SharedCaptureStorage.sharedDirectory.appendingPathComponent(asset.stagedFileName)
        guard try Data(contentsOf: staged) == markdown else { throw CheckError.failed("file URL content changed") }
        try FileManager.default.removeItem(at: staged)
    }

    private func load(_ provider: NSItemProvider) async -> LoadedProviderCapture? {
        await withCheckedContinuation { continuation in
            ShareCaptureRouteRunner.firstResult(
                in: ShareCaptureRoutePolicy.routes(for: provider.registeredTypeIdentifiers)
            ) { route, finish in
                ShareViewController.load(route, from: provider, completion: finish)
            } completion: { continuation.resume(returning: $0) }
        }
    }

    enum CheckError: Error { case failed(String) }
}
