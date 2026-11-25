import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class DiscussionOrderEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct OutlinerDiscussionOrderCheck {
    @MainActor static func main() async throws {
        let dates: [String: Any] = ["ownerUuid": "body", "properties": [[
            "attr": "logseq.property/scheduled", "title": "Scheduled", "kind": "datetime",
            "text": "Oct 23", "editable": true, "raw": ["type": "number", "value": 1792719000000]
        ], [
            "attr": "user.property/Assignee", "title": "Assignee", "kind": "string",
            "text": "Avery", "editable": true, "raw": ["type": "string", "value": "Avery"]
        ]]]
        let block: [String: Any] = ["uuid": "body", "title": "Parent", "pageId": "page", "taskDates": dates,
            "reactions": [["id": "+1", "count": 2]],
            "commentThreads": [["id": "thread", "comments": [["id": "comment", "text": "Example"]]]]]
        let result: [String: Any] = ["selectedGraphId": "demo", "graphName": "Demo",
            "selectedPage": ["uuid": "page", "title": "Properties"],
            "outlinerRows": [["depth": 0, "hasChildren": true, "block": block],
                ["depth": 1, "block": ["uuid": "child", "title": "Child", "pageId": "page"]]]]
        let snapshot = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: DiscussionOrderEffects())
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
        try runtime.applyCoreResponse(String(decoding: snapshot, as: UTF8.self))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true }

        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func frame(_ identifier: String) -> CGRect? {
            backend.rootIDs.flatMap(descendants).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }.flatMap { frames[$0] }
        }
        for _ in 0..<100 {
            if let property = frame("property.value.body.user.property/Assignee"),
               let discussion = frame("discussion.inline.body"),
               let child = frame("outliner.entry.child"),
               discussion.minY >= property.maxY - 1, discussion.maxY <= child.minY + 1 {
                print("PASS: reactions and comments are below bottom properties and above child blocks")
                return
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw NSError(domain: "OutlinerDiscussionOrder", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Expected bottom property, discussion, then child block"])
    }
}
