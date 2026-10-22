import Foundation
import SwiftUI
import UIKit
@testable import Logseq
@testable import LUIAppleBackend

@main struct CheckOutlinerRow {
    @MainActor static func main() async throws {
        let payload: [String: Any] = [
            "uuid": "row", "title": "Visible title", "markup": [], "depth": 2,
            "hasChildren": true, "collapsed": false, "isAsset": false,
            "assetType": "", "localPath": "", "youtubeURL": "", "completed": false,
            "selected": false, "opensAsPage": false, "journalBullet": false,
            "syncFailed": true, "status": ["uuid": "todo", "title": "Todo", "icon": "app:task-todo"],
            "statuses": [["uuid": "todo", "title": "Todo", "icon": "app:task-todo"]],
            "tags": [["uuid": "tag", "title": "Project"]]
        ]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let registry = try LGExtensionRegistry.makeRegistry()
        let backend = try LUIAppleBackend(appIcons: LGIconPolicy.icons, extensionRegistry: registry)
        let ops: [[String: Any]] = [
            ["op": "create-extension", "id": 1, "identifier": OutlinerRowExtension.identifier, "fingerprint": OutlinerRowExtension.fingerprint],
            ["op": "set-extension-prop", "id": 1, "property": "payload", "value": encoded]
        ]
        try backend.apply(json: String(decoding: try JSONSerialization.data(withJSONObject: ["generation": 1, "ops": ops]), as: UTF8.self))
        _ = try JSONDecoder().decode(OutlinerRowPayload.self, from: Data(encoded.utf8))
        let controller = UIHostingController(rootView: LUISwiftUIRoot(backend: backend, rootID: 1))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutIfNeeded()
        var seen = Set<ObjectIdentifier>()
        var elements: [NSObject] = []
        func collect(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            elements.append(object)
            if let children = object.accessibilityElements { for case let child as NSObject in children { collect(child) } }
            if let view = object as? UIView { for child in view.subviews { collect(child) } }
        }
        collect(controller.view)
        func element(_ identifier: String) -> NSObject? {
            elements.first { ($0 as? UIView)?.accessibilityIdentifier == identifier }
        }
        let identifiers = elements.compactMap { ($0 as? UIView)?.accessibilityIdentifier }
        print("ROW_ACCESSIBILITY identifiers=\(identifiers)")
        guard let title = element("outliner.block-action.row"),
              let tag = element("button.block-tag.tag"),
              element("button.outliner.collapse.row") != nil,
              element("button.block-task-status") != nil,
              element("outliner.sync-failed.row") != nil else {
            throw NSError(domain: "OutlinerRowCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native row controls must actually render"])
        }
        let disclosure = element("button.outliner.collapse.row") as! UIButton
        precondition(disclosure.bounds.width >= 44 && disclosure.bounds.height >= 44,
                     "Disclosure must have a full 44-point touch target")
        let nearEdge = CGPoint(x: disclosure.bounds.minX + 2, y: disclosure.bounds.maxY - 2)
        let pointInRow = disclosure.convert(nearEdge, to: disclosure.superview)
        precondition(disclosure.superview?.hitTest(pointInRow, with: nil) === disclosure,
                     "Tapping the edge of the disclosure target must not edit the title")
        var missing: [String] = []
        for identifier in ["button.outliner.zoom.row.Visible title", "button.block-task-status"] {
            guard let button = element(identifier) as? UIButton else { fatalError("Missing glyph control") }
            guard let image = button.image(for: .normal) else {
                missing.append("Missing visible glyph: " + identifier)
                continue
            }
            print("ROW_GLYPH id=\(identifier) image_size=\(image.size) image_frame=\(String(describing: button.imageView?.frame))")
            precondition(image.size.width > 0 && button.imageView!.bounds.width > 0,
                         "A glyph must have a visible layout, not only an accessibility identifier")
        }
        if element("outliner.indent-guides.row") == nil {
            missing.append("Missing ancestor guides aligned to parent bullets")
        }
        guard missing.isEmpty else {
            throw NSError(domain: "OutlinerRowCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: missing.joined(separator: "; ")])
        }
        guard let guide = element("outliner.indent-guides.row") as? UIView,
              let shape = guide.layer as? CAShapeLayer, let path = shape.path else {
            fatalError("Ancestor guides must have a rendered path")
        }
        var guidePoints: [CGPoint] = []
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
                guidePoints.append(element.pointee.points[0])
            }
        }
        precondition(guidePoints.count == 6, "Two ancestors and the expanded row must each draw a guide")
        for level in 0..<2 {
            precondition(guidePoints[level * 2] == CGPoint(x: OutlinerLayoutMetrics.bulletCenterX(depth: level), y: 0))
            precondition(guidePoints[level * 2 + 1].y == guide.bounds.height,
                         "Ancestor guides must reach the next virtual row")
        }
        precondition(guidePoints[4] == CGPoint(x: OutlinerLayoutMetrics.bulletCenterX(depth: 2), y: 17.5),
                     "The expanded parent guide starts below its bullet")
        let gap = tag.accessibilityFrame.minY - title.accessibilityFrame.maxY
        precondition(gap >= 0 && gap <= 4, "Tags must follow their title without an oversized gap")
        var events: [LUIEvent] = []
        backend.onEvent = { events.append($0) }
        if let button = tag as? UIButton { button.sendActions(for: .touchUpInside) }
        precondition(events.contains { if case .extension(_, _, "open-node", let values) = $0 { return values["uuid"] == .string("tag") }; return false })
        let native = elements.compactMap { $0 as? OutlinerTextRowView }.first!
        let statusButton = element("button.block-task-status") as! UIButton
        for (index, icon) in ["backlog", "todo", "doing", "done", "canceled", "review"].enumerated() {
            var updated = payload
            updated["status"] = ["uuid": icon, "title": icon, "icon": "app:task-" + icon]
            updated["collapsed"] = true
            updated["depth"] = index % 2
            let row = try JSONDecoder().decode(OutlinerRowPayload.self, from: JSONSerialization.data(withJSONObject: updated))
            native.update(row, emit: { _, _, _ in })
            native.layoutIfNeeded()
            guide.layoutIfNeeded()
            precondition(statusButton.image(for: .normal) != nil, "Every task status must have a visible glyph")
            precondition(guide.isHidden == (index % 2 == 0), "Reusing a row must clear stale ancestor guides")
        }
        print("PASS: visible bullets, all task glyphs, continuous ancestor guides, compact tags, and row reuse")
    }
}
