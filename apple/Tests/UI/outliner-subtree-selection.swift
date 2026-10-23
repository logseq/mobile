import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class SubtreeSelectionEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct OutlinerSubtreeSelectionCheck {
    @MainActor static func main() async throws {
        func snapshot(_ selected: [String]) throws -> String {
            let rows: [[String: Any]] = [("parent", 0, true), ("child", 1, true),
                ("grandchild", 2, false), ("sibling", 0, false)].map { uuid, depth, children in
                ["depth": depth, "hasChildren": children, "block": [
                    "uuid": uuid, "title": uuid.capitalized, "pageId": "page"]]
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": [
                "selectedGraphId": "demo", "graphName": "Subtree selection", "outlinerRows": rows,
                "outlinerState": ["selectedBlockIds": selected]]]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: SubtreeSelectionEffects())
        try runtime.applyCoreResponse(snapshot([]))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true; window.rootViewController = nil }
        let backend = runtime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func selectedRows() -> Set<String> {
            Set(backend.rootIDs.flatMap(descendants).compactMap { id in
                guard let node = backend.extensionModel(id: id), node.identifier == "outliner-block-row",
                      case let .string(payload) = node.properties["payload"],
                      let row = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                      row["selected"] as? Bool == true else { return nil }
                return row["uuid"] as? String
            })
        }
        for (selected, expected) in [(["parent"], Set(["parent", "child", "grandchild"])),
                                     (["child"], Set(["child", "grandchild"])), ([], Set<String>())] {
            try runtime.applyCoreResponse(snapshot(selected))
            try await Task.sleep(for: .milliseconds(450))
            guard selectedRows() == expected else {
                throw NSError(domain: "SubtreeSelection", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Selected parent must highlight its native descendants: got \(selectedRows()), expected \(expected)"])
            }
            if selected == ["parent"] {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("subtree-selection.png"))
            }
        }
        print("PASS: native parent and child selection highlights descendants, excludes siblings, and clears on Unselect")
    }
}
