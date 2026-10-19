import ImageIO
import LogseqModel
import SwiftUI

#if os(iOS)
enum LGGraphAssetLoader {
    private struct Response: Decodable {
        let ok: Bool
        let result: Result?
        let error: LogseqCoreError?
        struct Result: Decodable {
            let graphId: String
            let localPath: String?
            let request: LogseqPendingSyncRequest?
        }
    }

    static func load(uuid: String, assetType: String) async throws -> URL {
        var metadata = ["uuid": uuid, "assetType": assetType]
        func call(_ action: String, _ fields: [String: String]) async throws -> Response.Result {
            let payload = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
            let encoded = await LogseqCore.callAsync(LogseqRPCRequest(method: "dispatch",
                params: LogseqRPCParams(action: action, payload: payload)))
            let response = try JSONDecoder().decode(Response.self, from: Data(encoded.utf8))
            guard response.ok, let result = response.result else {
                throw NSError(domain: "LogseqAsset", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: response.error?.message ?? "Asset download failed"
                ])
            }
            return result
        }
        let prepared = try await call("prepareAssetDownload", metadata)
        if let path = prepared.localPath { return URL(fileURLWithPath: path) }
        guard let pending = prepared.request, let url = URL(string: pending.url) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = pending.method
        request.setValue("Bearer " + pending.token, forHTTPHeaderField: "Authorization")
        let (download, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: download, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        metadata["graphId"] = prepared.graphId
        metadata["path"] = temporary.path
        let cached = try await call("cacheDownloadedAsset", metadata)
        guard let path = cached.localPath else { throw URLError(.cannotCreateFile) }
        return URL(fileURLWithPath: path)
    }
}

private final class LGInlineImageThumbnailBox {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

private final class LGInlineImageThumbnailCache: @unchecked Sendable {
    static let shared = LGInlineImageThumbnailCache()

    private let cache = NSCache<NSURL, LGInlineImageThumbnailBox>()

    private init() {
        cache.countLimit = 80
    }

    func image(for url: URL) -> CGImage? {
        cache.object(forKey: url as NSURL)?.image
    }

    func store(_ image: CGImage, for url: URL) {
        cache.setObject(LGInlineImageThumbnailBox(image), forKey: url as NSURL)
    }
}

struct LGInlineImage: View {
    private static let maximumPreviewSize = CGSize(width: 326, height: 280)

    let url: URL
    @State private var thumbnail: CGImage?

    init(url: URL) {
        self.url = url
        _thumbnail = State(
            initialValue: LGInlineImageThumbnailCache.shared.image(for: url)
        )
    }

    var body: some View {
        Group {
            if let thumbnail {
                let displaySize = Self.displaySize(for: thumbnail)
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .frame(width: displaySize.width, height: displaySize.height)
                    .clipShape(.rect(cornerRadius: 8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().frame(height: 120)
            }
        }
        .accessibilityIdentifier("asset.preview.image")
        .task(id: url) {
            if let cached = LGInlineImageThumbnailCache.shared.image(for: url) {
                thumbnail = cached
                return
            }
            let imageURL = url
            let image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, [
                    kCGImageSourceShouldCache: false,
                ] as CFDictionary) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1200,
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            if let image {
                LGInlineImageThumbnailCache.shared.store(image, for: imageURL)
            }
            thumbnail = image
        }
    }

    private static func displaySize(for image: CGImage) -> CGSize {
        let width = max(CGFloat(image.width), 1)
        let height = max(CGFloat(image.height), 1)
        let scale = min(
            maximumPreviewSize.width / width,
            maximumPreviewSize.height / height,
            1
        )
        return CGSize(width: ceil(width * scale), height: ceil(height * scale))
    }
}
#endif
