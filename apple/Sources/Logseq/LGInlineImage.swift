import ImageIO
import LogseqModel
import SwiftUI

typealias LGImageDimensions = LogseqImageDimensions

extension LogseqImageDimensions {
    var previewSize: CGSize? {
        guard width > 0, height > 0 else { return nil }
        let width = CGFloat(width)
        let height = CGFloat(height)
        let scale = min(326 / width, 280 / height, 1)
        return CGSize(width: ceil(width * scale), height: ceil(height * scale))
    }

    static func read(at url: URL) -> Self? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? Self(width: height, height: width) : Self(width: width, height: height)
    }
}

#if os(iOS)
@MainActor enum LGGraphAssetLoader {
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

    static func load(uuid: String, assetType: String, expectedGraphId: String? = nil, feedbackTitle: String? = nil,
                     callCore: (LogseqRPCRequest) async -> String = { await LogseqCore.callAsync($0) },
                     downloadFile: (URLRequest) async throws -> (URL, URLResponse) = {
                         try await URLSession.shared.download(for: $0)
                     }) async throws -> URL {
        var metadata = ["uuid": uuid, "assetType": assetType]
        func call(_ action: String, _ fields: [String: String]) async throws -> Response.Result {
            let payload = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
            let encoded = await callCore(LogseqRPCRequest(method: "dispatch",
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
        if let expectedGraphId, prepared.graphId != expectedGraphId { throw CancellationError() }
        if let path = prepared.localPath { return URL(fileURLWithPath: path) }
        if let feedbackTitle {
            return try await LGFileDownloadFeedback.shared.download(title: feedbackTitle) {
                try await download()
            }
        }
        return try await download()

        func download() async throws -> URL {
            guard let pending = prepared.request, let url = URL(string: pending.url) else {
                throw URLError(.badURL)
            }
            var request = URLRequest(url: url)
            request.httpMethod = pending.method
            request.setValue("Bearer " + pending.token, forHTTPHeaderField: "Authorization")
            let (download, response) = try await downloadFile(request)
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
    private let sizes = NSCache<NSURL, NSValue>()

    private init() {
        cache.countLimit = 80
        sizes.countLimit = 256
    }

    func image(for url: URL) -> CGImage? {
        cache.object(forKey: url as NSURL)?.image
    }

    func store(_ image: CGImage, for url: URL) {
        cache.setObject(LGInlineImageThumbnailBox(image), forKey: url as NSURL)
    }

    func previewSize(for url: URL) -> CGSize? {
        if let cached = sizes.object(forKey: url as NSURL) { return cached.cgSizeValue }
        guard let size = LGImageDimensions.read(at: url)?.previewSize else { return nil }
        sizes.setObject(NSValue(cgSize: size), forKey: url as NSURL)
        return size
    }
}

struct LGInlineImage: View {
    let url: URL
    let dimensions: LGImageDimensions?
    @State private var thumbnail: CGImage?

    init(url: URL, dimensions: LGImageDimensions? = nil) {
        self.url = url
        self.dimensions = dimensions
        _thumbnail = State(
            initialValue: LGInlineImageThumbnailCache.shared.image(for: url)
        )
    }

    var body: some View {
        let size = dimensions?.previewSize ?? LGInlineImageThumbnailCache.shared.previewSize(for: url)
        Group {
            if let thumbnail {
                let displaySize = size ?? LGImageDimensions(width: thumbnail.width, height: thumbnail.height).previewSize
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(width: displaySize?.width, height: displaySize?.height)
                    .clipShape(.rect(cornerRadius: 8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Self.placeholder(size: size) { ProgressView() }
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

    static func placeholder<Content: View>(size: CGSize?, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: size?.width, height: size?.height ?? 120)
            .background {
                if size != nil {
                    RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.08))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
