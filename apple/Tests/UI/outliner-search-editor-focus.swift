import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@main struct OutlinerSearchEditorFocusCheck {
    @MainActor static func main() async throws {
        var routes: [String] = []
        var editing = false
        let row: [String: Any] = ["depth": 0, "block": ["uuid": "target", "title": "Hello world",
            "pageId": "journal", "journalDay": 20261023, "journalTitle": "Today"]]
        func snapshot() throws -> String {
            let state: [String: Any] = editing
                ? ["editing": ["uuid": "target", "title": "Hello world", "caretUTF16Offset": 11]]
                : ["selectedBlockIds": []]
            let projections: [[String: Any]] = routes.map { uuid in
                ["uuid": uuid, "page": ["uuid": "journal", "title": "Today"],
                 "outlinerRows": [row], "outlinerState": state]
            }
            let result: [String: Any] = ["selectedGraphId": "demo", "graphName": "Demo",
                "outlinerRows": [row], "outlinerState": state, "nodeRoutes": projections,
                "searchQuery": "Today", "searchResults": [["uuid": "journal", "title": "Today", "isPage": true]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { request in
            if let data = request.params.payload?.data(using: .utf8),
               let effect = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                switch effect["kind"] as? String {
                case "open-node", "open-search-result":
                    if let uuid = effect["text"] as? String { routes.append(uuid); editing = false }
                case "close-node": _ = routes.popLast(); editing = false
                case "tap-outliner-block": editing = true
                default: break
                }
            }
            return try! snapshot()
        }))
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer).ignoresSafeArea(.keyboard))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        let backend = runtime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).last { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier }
        }
        func editors() -> [UITextView] { views(window).compactMap { $0 as? UITextView }.filter {
            $0.accessibilityIdentifier == "field.outliner.block.target"
        } }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure(message)
        }
        try await Task.sleep(for: .milliseconds(400))
        try backend.performPress(node: find("button.search")!)
        try await wait("Search must focus its native input") {
            views(window).contains { ($0 as? UISearchTextField)?.isFirstResponder == true }
        }
        views(window).compactMap { $0 as? UISearchTextField }.first { $0.isFirstResponder }!.insertText("Today")
        try await wait("Search result must appear") { find("search.result.journal") != nil }
        try backend.performPress(node: find("search.result.journal")!)
        try await wait("Search must open the page") { routes == ["journal"] }
        try await Task.sleep(for: .milliseconds(650))
        // Also cover following a link from that search destination.
        for nested in [false, true] {
            if nested {
                guard let row = backend.rootIDs.flatMap(descendants).last(where: {
                    backend.extensionModel(id: $0)?.identifier == "outliner-block-row"
                }) else { throw failure("The search page must retain its linked row") }
                try backend.performExtensionEvent(node: row, name: "open-node", values: ["uuid": .string("target")])
                try await wait("The linked block must push above the search page") { routes.count == 2 }
                try await Task.sleep(for: .milliseconds(650))
            }
            guard let target = backend.rootIDs.flatMap(descendants).last(where: {
                guard let node = backend.extensionModel(id: $0), node.identifier == "outliner-block-row",
                      case let .string(payload) = node.properties["payload"] else { return false }
                return payload.contains("target")
            }) else { throw failure("The search destination must render its block") }
            try backend.performExtensionEvent(node: target, name: "edit", values: ["uuid": .string("target")])
            try await wait("Tapping the block must enter editing") { !editors().isEmpty }
            try await Task.sleep(for: .milliseconds(450))
            guard editors().count == 1, let editor = editors().first, editor.isFirstResponder else {
                throw failure("Search destination nested=\(nested) must own one visible focused editor; found \(editors().count)")
            }
            for offset in [2, 7, 0] {
                editor.selectedRange = NSRange(location: offset, length: 0)
                editor.delegate?.textViewDidChangeSelection?(editor)
                try runtime.applyCoreResponse(snapshot())
                try await Task.sleep(for: .milliseconds(150))
                guard editors().count == 1, editors().first === editor, editor.isFirstResponder,
                      editor.selectedRange == NSRange(location: offset, length: 0) else {
                    throw failure("Search destination nested=\(nested) lost its native caret tap at \(offset)")
                }
            }
        }
        print("PASS: search-result pages and links from search retain one visible cursor and preserve caret taps")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "SearchEditorFocus", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
