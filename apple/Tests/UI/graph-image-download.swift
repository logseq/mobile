import Foundation
import SwiftUI
import ImageIO
import LogseqModel
@testable import Logseq

@main struct GraphImageDownloadCheck: App {
    @State private var imageURL: URL?
    var body: some Scene {
        WindowGroup {
            Group {
                if let imageURL { LGInlineImage(url: imageURL) }
                else { Text("Image download check") }
            }
            .task {
                do {
                    func call(_ method: String = "dispatch", action: String? = nil, payload: String? = nil, path: String? = nil) async -> String {
                        await LogseqCore.callAsync(LogseqRPCRequest(method: method,
                            params: LogseqRPCParams(action: action, payload: payload, path: path)))
                    }
                    let documents = URL.documentsDirectory
                    _ = await call("open", path: documents.appendingPathComponent("logseq.sqlite").path)
                    _ = await call(action: "configure", payload: #"{"graphId":"uiregression","baseUrl":"http://127.0.0.1:18763","token":"test-token"}"#)
                    let graph = documents.appendingPathComponent("graphs/uiregression")
                    let payload = String(decoding: try JSONSerialization.data(withJSONObject: [
                        "graphId": "uiregression", "activePath": graph.appendingPathComponent("graph.sqlite").path,
                        "checkpointPath": graph.appendingPathComponent("sync.checkpoint").path, "isEncrypted": false
                    ]), as: UTF8.self)
                    _ = await call(action: "openGraph", payload: payload)
                    let downloaded = try await LGGraphAssetLoader.load(uuid: "test-image", assetType: "image/png")
                    precondition(FileManager.default.fileExists(atPath: downloaded.path))
                    precondition(CGImageSourceCreateWithURL(downloaded as CFURL, nil) != nil,
                                 "Synced graph downloads must be usable by the inline image renderer")
                    let cached = try await LGGraphAssetLoader.load(uuid: "test-image", assetType: "png")
                    precondition(cached == downloaded, "Reopening an image must reuse the graph cache")
                    imageURL = cached
                    try await Task.sleep(for: .milliseconds(800))
                    print("PASS: synced image downloaded through authenticated assets API and rendered from persistent cache")
                    print("RUNTIME_CHECK_COMPLETE")
                    exit(0)
                } catch {
                    print("RUNTIME_CHECK_FAILED: \(error)")
                    exit(1)
                }
            }
        }
    }
}
