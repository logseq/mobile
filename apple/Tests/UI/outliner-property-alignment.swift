import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class AlignmentEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct OutlinerPropertyAlignmentCheck {
    @MainActor static func main() async throws {
        func properties(_ owner: String) -> [String: Any] {
            ["ownerUuid": owner, "properties": ["scheduled", "deadline"].map { name in
                ["attr": "logseq.property/" + name, "title": name.capitalized,
                 "kind": "datetime", "text": "Oct 23, 09:30", "editorValue": "1792719000000",
                 "editable": true, "textLayout": false, "raw": ["type": "number", "value": 1792719000000]] as [String: Any]
            }]
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: AlignmentEffects())
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier }
        }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func snapshot(_ variant: Int) throws -> String {
            var block: [String: Any] = ["uuid": "body", "title": "Hello", "pageId": "page", "taskDates": properties("body")]
            if variant & 1 != 0 { block["status"] = ["uuid": "todo", "title": "Todo", "icon": "app:task-todo"] }
            if variant & 2 != 0 { block["priority"] = ["uuid": "high", "title": "High", "icon": "app:priority-high"] }
            let result: [String: Any] = ["selectedGraphId": "demo", "graphName": "Demo",
                "selectedPage": ["uuid": "page", "title": "Properties"], "nodeProperties": properties("page"),
                "outlinerRows": [["depth": variant % 2, "hasChildren": true, "isCollapsed": false, "block": block],
                    ["depth": variant % 2 + 1, "block": ["uuid": "child", "title": "Child", "pageId": "page"]]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        try runtime.applyCoreResponse(snapshot(0))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true }
        var failures: [String] = []
        for variant in 0..<4 {
            try runtime.applyCoreResponse(snapshot(variant))
            try await Task.sleep(for: .milliseconds(500))
            window.layoutIfNeeded()
            guard let title = views(window).first(where: { $0.accessibilityIdentifier == "outliner.block-action.body" }) else { fatalError("Missing title") }
            let titleFrame = title.convert(title.bounds, to: window)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("alignment-\(variant).png"))
            for name in ["scheduled", "deadline"] {
                let attr = "logseq.property/" + name
                guard let labelID = find("property.label.body." + attr), let key = frames[labelID],
                      let value = find("property.value.body." + attr).flatMap({ frames[$0] }),
                      let pageID = find("property.label.page." + attr) else { fatalError("Missing property") }
                print("PROPERTY variant=\(variant) title=\(titleFrame) label=\(key) value=\(value)")
                if name == "scheduled", abs(key.minX - titleFrame.minX) > 1 { failures.append("Outliner \(variant) must align with text") }
                if name == "deadline", let scheduled = find("property.label.body.logseq.property/scheduled").flatMap({ frames[$0] }),
                   abs(key.midY - scheduled.midY) > 1 { failures.append("Task dates must share one line") }
                if abs(key.width - 20) > 1 || value.minX - key.maxX > 9 { failures.append("Inline dates retain compact icons") }
                if backend.model(id: pageID)?.property(.text)?.stringValue != name.capitalized {
                    failures.append("Page dates must use ordinary text labels: \(name)")
                }
            }
            guard let guide = views(window).first(where: { $0.accessibilityIdentifier == "outliner.indent-guides.metadata.body" }),
                  let shape = guide.layer as? CAShapeLayer, let path = shape.path,
                  let child = views(window).first(where: { $0.accessibilityIdentifier == "outliner.block-action.child" }) else {
                failures.append("Properties must continue the ancestor and child guides")
                continue
            }
            let guideFrame = guide.convert(guide.bounds, to: window)
            let childFrame = child.convert(child.bounds, to: window)
            var segments: [CGPoint] = []
            path.applyWithBlock { element in
                if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
                    segments.append(element.pointee.points[0])
                }
            }
            if segments.count != (variant % 2 + 1) * 2 || segments.contains(where: { $0.y != 0 && abs($0.y - guide.bounds.height) > 0.1 }) {
                failures.append("Every metadata guide must span its full height")
            }
            if abs(guideFrame.minY - titleFrame.maxY - 2) > 0.5 || abs(guideFrame.maxY - childFrame.minY + 2) > 0.5 {
                failures.append("Property guides must join both adjacent block rows: \(guideFrame), \(titleFrame), \(childFrame)")
            }
        }
        for name in ["scheduled", "deadline"] {
            try backend.performPress(node: find("property.value.body.logseq.property/" + name)!)
            for _ in 0..<100 {
                if views(window).contains(where: { $0 is UIDatePicker }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if !views(window).contains(where: { $0 is UIDatePicker }) { failures.append("Inline \(name) must open a native picker") }
            guard let cancel = find("view.edit.cancel.property.body.logseq.property/" + name) else { fatalError("Missing date editor Cancel") }
            try backend.performPress(node: cancel)
            try await Task.sleep(for: .milliseconds(350))
        }
        guard failures.isEmpty else { throw NSError(domain: "PropertyAlignment", code: 1,
            userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]) }
        print("PASS: outliner properties align with text for nested, status and priority rows; page dates use labels")
    }
}
