import SwiftUI
import UIKit
import Vision
@testable import LUIAppleBackend
@testable import Logseq

@main struct SearchResultsLayoutCheck {
    @MainActor static func main() async throws {
        var query = ""
        var finishSearch: CheckedContinuation<Void, Never>?
        let hits: [[String: Any]] = (0..<80).map {
            ["uuid": "result-\($0)", "title": "Needle result \($0)", "isPage": $0 < 40]
        }
        func snapshot() -> String {
            let result: [String: Any] = ["graphName": "Search layout", "selectedGraphId": "layout",
                "searchQuery": query, "searchResults": query.isEmpty ? [] : hits]
            return String(decoding: try! JSONSerialization.data(withJSONObject:
                ["ok": true, "result": result]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(),
            effectExecutor: LGCoreEffectExecutor(callCore: { request in
                if let data = request.params.payload?.data(using: .utf8),
                   let effect = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   effect["kind"] as? String == "search-nodes" {
                    await withCheckedContinuation { finishSearch = $0 }
                    query = effect["text"] as? String ?? ""
                }
                return snapshot()
            }))
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? [])
                .flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure(message)
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer {
            finishSearch?.resume()
            window.isHidden = true
            window.rootViewController = nil
            runtime.stop()
        }
        try await Task.sleep(for: .milliseconds(300))
        let search = backend.rootIDs.flatMap(descendants).first {
            backend.extensionModel(id: $0)?.identifier == "native-search-presentation"
        }!
        try backend.performExtensionEvent(node: search, name: "present", values: [:])
        try await wait("Search must accept input") {
            views(window).contains { ($0 as? UISearchTextField)?.isFirstResponder == true }
        }
        let field = views(window).compactMap { $0 as? UISearchTextField }.first { $0.isFirstResponder }!
        field.insertText("Needle")
        try await wait("Search must start") { finishSearch != nil }
        try await Task.sleep(for: .milliseconds(300))
        func topbarText() throws -> String {
            // Include the window background behind the transparent native bar.
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.regionOfInterest = CGRect(x: 0, y: 0.8, width: 1, height: 0.2)
            try VNImageRequestHandler(cgImage: image.cgImage!).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
        let loadingTitle = try topbarText()
        guard loadingTitle.contains("Searching") else {
            throw failure("Pending search must display Searching… in the visible topbar; got: \(loadingTitle)")
        }
        finishSearch?.resume()
        finishSearch = nil
        try await wait("Search results must render") { find("search.result.result-0") != nil }
        try await Task.sleep(for: .milliseconds(300))
        let resultTitle = try topbarText()
        guard resultTitle.contains("80 results"), field.placeholder == "Search" else {
            throw failure("The topbar must display the result count while the input keeps its Search prompt; got: \(resultTitle)")
        }
        guard find("search.status") == nil, find("search.loading") == nil else {
            throw failure("Search status must not occupy a separate row above the results")
        }
        guard let list = views(window).compactMap({ $0 as? UICollectionView }).first(where: {
            $0.bounds.height > 200 && $0.contentSize.height > $0.bounds.height
        }) else { throw failure("Missing the native search results list") }
        for offset: CGFloat in [0, 300, 2400, 2900] {
            list.setContentOffset(CGPoint(x: 0, y: min(offset, list.contentSize.height - list.bounds.height)), animated: false)
            try await Task.sleep(for: .milliseconds(150))
            guard list.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader).isEmpty else {
                throw failure("Pages and Blocks must scroll as ordinary rows, without pinned section headers; offset=\(offset)")
            }
        }
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try screenshot.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("search-results-layout.png"))
        guard runtime.lastError == nil else { throw failure(runtime.lastError!) }
        print("PASS: Searching… and result count render in the topbar; Pages and Blocks have no pinned section headers")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SearchResultsLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
