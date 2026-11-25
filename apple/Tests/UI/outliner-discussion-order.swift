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
        try await check(openedBlock: false)
        try await check(openedBlock: true)
        print("PASS: discussions follow task dates and custom properties, above child blocks")
    }

    @MainActor private static func check(openedBlock: Bool) async throws {
        let dates: [String: Any] = ["ownerUuid": "body", "properties": [[
            "attr": "logseq.property/scheduled", "title": "Scheduled", "kind": "datetime",
            "text": "Oct 23", "editable": true, "raw": ["type": "number", "value": 1792719000000]
        ]]]
        let customProperties: [String: Any] = ["ownerUuid": "body", "properties": [[
            "attr": "user.property/Assignee", "title": "Assignee", "kind": "string",
            "text": "Avery", "editable": true, "raw": ["type": "string", "value": "Avery"]
        ]]]
        let block: [String: Any] = ["uuid": "body", "title": "Parent", "pageId": "page", "taskDates": dates,
            "reactions": [["id": "+1", "count": 2]],
            "commentThreads": [["id": "thread", "comments": [["id": "comment", "text": "Example"]]]]]
        let rows: [[String: Any]] = [["depth": 0, "hasChildren": true, "block": block],
            ["depth": 1, "block": ["uuid": "child", "title": "Child", "pageId": "page"]]]
        let page = ["uuid": "page", "title": "Properties"]
        var result: [String: Any] = ["selectedGraphId": "demo", "graphName": "Demo",
            "selectedPage": page, "outlinerRows": rows]
        if openedBlock {
            result["nodeRoutes"] = [["uuid": "body", "title": "Parent", "page": page,
                "outlinerRows": rows, "nodeProperties": customProperties]]
        }
        let snapshot = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: DiscussionOrderEffects())
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
        try runtime.applyCoreResponse(String(decoding: snapshot, as: UTF8.self))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        if openedBlock { try runtime.applyHostUpdate(kind: "open-node", payload: #""body""#) }

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true }

        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func frame(_ identifier: String) -> CGRect? {
            backend.rootIDs.flatMap(descendants).compactMap { id -> CGRect? in
                guard backend.model(id: id)?.property(.accessibilityIdentifier)?.stringValue == identifier else { return nil }
                return frames[id]
            }.last
        }
        let property = "property.value.body." + (openedBlock ? "user.property/Assignee" : "logseq.property/scheduled")
        for _ in 0..<100 {
            if let propertyFrame = frame(property),
               let discussion = frame("discussion.inline.body"),
               let child = frame("outliner.entry.child"),
               discussion.minY >= propertyFrame.maxY - 1, discussion.maxY <= child.minY + 1 {
                return
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw NSError(domain: "OutlinerDiscussionOrder", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Expected \(property), discussion, then child block"])
    }
}
