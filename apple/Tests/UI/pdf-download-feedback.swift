import PDFKit
import SwiftUI
import UIKit
import LogseqModel
@testable import Logseq

private struct PDFDownloadReader: UIViewControllerRepresentable {
    let controller: LGPDFReaderController
    func makeUIViewController(context: Context) -> LGPDFReaderController { controller }
    func updateUIViewController(_ controller: LGPDFReaderController, context: Context) {}
}

@main struct PDFDownloadFeedbackCheck {
    @MainActor static func main() async throws {
        let original = URL.temporaryDirectory.appendingPathComponent("feedback-original.pdf")
        let cached = URL.temporaryDirectory.appendingPathComponent("feedback-cached.pdf")
        let transferred = URL.temporaryDirectory.appendingPathComponent("feedback-transfer.pdf")
        try? FileManager.default.removeItem(at: cached)
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).writePDF(to: original) { context in
            for page in 1...3 {
                context.beginPage()
                NSString(string: "Downloaded annotation page \(page)").draw(at: CGPoint(x: 40, y: 80))
            }
        }
        defer { for file in [original, cached, transferred] { try? FileManager.default.removeItem(at: file) } }
        let feedback = LGFileDownloadFeedback.shared
        var cacheSawDownloading = false
        var requestValidated = false
        var cacheHit = false
        var transfers = 0
        func core(_ request: LogseqRPCRequest) async -> String {
            var result: [String: Any] = ["graphId": "download-check"]
            if request.params.action == "prepareAssetDownload" {
                if cacheHit { result["localPath"] = cached.path }
                else { result["request"] = ["id": 1, "url": "https://assets.invalid/annotation.pdf", "method": "GET", "token": "fixture-token", "contentType": "application/pdf"] }
            } else {
                cacheSawDownloading = feedback.notice?.phase == .downloading
                // Keep the progress notice until decryption/cache persistence has completed.
                try? await Task.sleep(for: .milliseconds(300))
                let fields = try! JSONSerialization.jsonObject(with: Data(request.params.payload!.utf8)) as! [String: String]
                try! FileManager.default.copyItem(atPath: fields["path"]!, toPath: cached.path)
                result["localPath"] = cached.path
            }
            return String(decoding: try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let reader = LGPDFReaderController()
        reader.loadAsset = { uuid, title in
            try await LGGraphAssetLoader.load(uuid: uuid, assetType: "pdf", feedbackTitle: title, callCore: core, downloadFile: { request in
                transfers += 1
                requestValidated = request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token"
                try await Task.sleep(for: .milliseconds(900))
                try FileManager.default.copyItem(at: original, to: transferred)
                return (transferred, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: PDFDownloadReader(controller: reader)
            .modifier(LGFileDownloadFeedbackHost()).environment(\.locale, Locale(identifier: "zh-CN")))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw failure(message)
        }
        func screenshot(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(name))
        }
        var payload: [String: Any] = ["graphId": "download-check", "assetUuid": "pdf-check", "title": "批注原文件.pdf",
                      "path": "", "loading": false, "targetPage": 2, "targetAnnotation": "annotation-2", "navigationToken": 1]
        reader.apply(payload)
        try await wait("Missing annotation files must show download progress") { feedback.notice?.phase == .downloading }
        guard reader.pdfView.document == nil, feedback.notice?.title == "批注原文件.pdf" else { throw failure("Progress must precede document presentation") }
        try await Task.sleep(for: .milliseconds(250))
        payload["targetPage"] = 3
        payload["targetAnnotation"] = "annotation-3"
        payload["navigationToken"] = 2
        reader.apply(payload)
        try screenshot("pdf-downloading.png")
        try await wait("Download must complete and open the requested annotation page") {
            guard let document = reader.pdfView.document, let page = reader.pdfView.currentPage else { return false }
            return feedback.notice?.phase == .completed && document.index(for: page) == 2
        }
        guard cacheSawDownloading, requestValidated, transfers == 1 else { throw failure("Feedback must span authenticated transfer and cache persistence without re-downloading for another annotation") }
        try screenshot("pdf-download-complete.png")

        cacheHit = true
        let completionID = feedback.notice?.id
        _ = try await LGGraphAssetLoader.load(uuid: "pdf-check", assetType: "pdf", feedbackTitle: "Cached.pdf", callCore: core,
            downloadFile: { _ in throw failure("Cached files must bypass the network") })
        guard feedback.notice?.id == completionID else { throw failure("Cached files must not create download notices") }
        cacheHit = false
        do {
            _ = try await LGGraphAssetLoader.load(uuid: "failed", assetType: "pdf", feedbackTitle: "Failed.pdf", callCore: core,
                downloadFile: { request in (original, HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!) })
            throw failure("HTTP errors must fail the download")
        } catch let error as URLError where error.code == .badServerResponse {}
        guard feedback.notice?.phase == .failed else { throw failure("Failed downloads must notify the user") }

        let cancelled = Task {
            try await LGGraphAssetLoader.load(uuid: "cancelled", assetType: "pdf", feedbackTitle: "Cancelled.pdf", callCore: core,
                downloadFile: { _ in try await Task.sleep(for: .seconds(10)); throw CancellationError() })
        }
        try await wait("Cancellation check must start downloading") { feedback.notice?.phase == .downloading }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw failure("Cancelled download must not succeed") }
        catch is CancellationError {}
        guard feedback.notice == nil else { throw failure("Cancellation must clear progress without a failure notice") }
        print("PASS: missing annotation PDF shows progress through cache, announces completion, opens page 3, bypasses cache hits, reports HTTP failure, and cancels cleanly")
    }

    static func failure(_ message: String) -> NSError { NSError(domain: "PDFDownloadFeedback", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
