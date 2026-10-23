import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

private final class RetentionImageProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var image = Data()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "image-retention.logseq.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let data = Self.image
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: URLResponse(url: request.url!, mimeType: "image/png",
            expectedContentLength: data.count, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func requestCount() -> Int { lock.lock(); defer { lock.unlock() }; return requests }
}

@MainActor private final class RetentionEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct OutlinerEditorRetentionCheck {
    @MainActor static func main() async throws {
        RetentionImageProtocol.image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 48)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 96, height: 48))
        }.pngData()!
        URLProtocol.registerClass(RetentionImageProtocol.self)
        defer { URLProtocol.unregisterClass(RetentionImageProtocol.self) }
        func row(_ uuid: String, _ title: String, day: Int, markup: [[String: Any]]? = nil) -> [String: Any] {
            var block: [String: Any] = ["uuid": uuid, "title": title, "pageId": "page-\(day)",
                "journalDay": day, "journalTitle": day == 20261023 ? "Today" : "Yesterday"]
            if let markup { block["markup"] = markup }
            return ["depth": 0, "block": block]
        }
        func snapshot(_ editing: Bool) throws -> String {
            let result: [String: Any] = ["selectedGraphId": "demo", "graphName": "Demo", "outlinerRows": [
                row("today", "Today block", day: 20261023),
                row("target", "Nice", day: 20261022),
                row("photo", "Photo", day: 20261022, markup: [["type": "image", "text": "Photo",
                    "url": "https://image-retention.logseq.test/photo.png"]])],
                "outlinerState": editing ? ["editing": ["uuid": "target", "title": "Nice", "caretUTF16Offset": 4]] : ["selectedBlockIds": []]]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: RetentionEffects())
        try runtime.applyCoreResponse(snapshot(false))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer).ignoresSafeArea(.keyboard))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        for _ in 0..<60 {
            if RetentionImageProtocol.requestCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(400))
        guard RetentionImageProtocol.requestCount() > 0 else { throw failure("The native image must load before checking retention") }
        let initialLoads = RetentionImageProtocol.requestCount()
        let label = views(window).first { $0.accessibilityIdentifier == "outliner.block-action.target" }!
        let originalFrame = label.convert(label.bounds, to: window)
        var failures: [String] = []
        for editing in [true, false, true, false] {
            try runtime.applyCoreResponse(snapshot(editing))
            try await Task.sleep(for: .milliseconds(450))
            let identifier = editing ? "field.outliner.block.target" : "outliner.block-action.target"
            guard let content = views(window).first(where: { $0.accessibilityIdentifier == identifier }) else {
                throw failure("The target block must remain visible")
            }
            let frame = content.convert(content.bounds, to: window)
            if abs(frame.minY - originalFrame.minY) > 0.5 { failures.append("Target moved from \(originalFrame.minY) to \(frame.minY)") }
            if RetentionImageProtocol.requestCount() != initialLoads { failures.append("An unchanged image reloaded during editing") }
        }
        guard failures.isEmpty else { throw failure(failures.joined(separator: "; ")) }
        print("PASS: entering and leaving editing across journal sections preserves block positions and loaded images")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "EditorRetention", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
