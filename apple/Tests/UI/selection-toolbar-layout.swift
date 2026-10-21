import UIKit
import SwiftUI
@testable import LUIAppleBackend
@testable import Logseq

@main struct SelectionToolbarLayoutCheck {
    @MainActor static func main() async throws {
        let snapshot = #"{"ok":true,"result":{"graphName":"Work","selectedGraphId":"work","outlinerRows":[{"block":{"uuid":"selected","title":"Selected block","pageId":"page"},"depth":0}],"outlinerState":{"selectedBlockIds":["selected"]}}}"#
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { _ in snapshot }))
        try runtime.applyCoreResponse(snapshot)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func model(_ identifier: String) throws -> LUINodeModel {
            guard let model = backend.rootIDs.flatMap(descendants).compactMap({ backend.model(id: $0) })
                .first(where: { $0.property(.accessibilityIdentifier)?.stringValue == identifier }) else {
                throw failure("Missing control: " + identifier)
            }
            return model
        }
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        window.makeKeyAndVisible()
        for width in [CGFloat(375), CGFloat(393), CGFloat(820)] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: scene.screen.bounds.height)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(900))
            let toolbar = try model("toolbar.outliner.selection")
            guard toolbar.property(.placement)?.stringValue == "bottom" else {
                throw failure("Selection actions must use native bottom-toolbar capsules")
            }
            // Hoisted controls intentionally omit LUI's inline frame reports.
            // Measure the actual native scroll viewport and its laid-out cells.
            func descendants(_ view: UIView) -> [UIView] {
                [view] + view.subviews.flatMap(descendants)
            }
            let views = descendants(window)
            func rect(_ view: UIView) -> CGRect { view.convert(view.bounds, to: window) }
            guard let scroll = views.compactMap({ $0 as? UIScrollView }).first(where: {
                $0.bounds.height >= 44 && $0.bounds.height <= 60 && rect($0).minY > window.bounds.height - 120
            }) else { throw failure("Missing native selection scroll viewport") }
            let viewport = rect(scroll)
            guard let cells = descendants(scroll).first(where: {
                $0.subviews.count == 6 && $0.subviews.allSatisfy {
                    $0.bounds.width >= 44 && $0.bounds.height >= 44
                }
            })?.subviews else { throw failure("Missing native selection action cells") }
            for (index, name) in ["copy", "outdent", "indent", "delete", "copyReference"].enumerated() {
                _ = try model("button.outliner.selection." + name)
                let frame = rect(cells[index])
                guard frame.minX >= viewport.minX - 0.5, frame.maxX <= viewport.maxX + 0.5,
                    frame.width >= 44, frame.height >= 44 else {
                    throw failure("Five full-size actions must fit in the capsule at width \(width): \(name), \(frame), viewport \(viewport)")
                }
                print("SELECTION width=\(width) action=\(name) frame=\(frame)")
            }
            let unselect = try model("button.outliner.selection.unselect")
            let unselectWidth = CGFloat(unselect.property(.width)?.intValue ?? 0)
            guard let trailing = views.first(where: {
                abs($0.bounds.width - unselectWidth) < 0.5 && abs($0.bounds.height - 46) < 0.5
                    && rect($0).minX > viewport.maxX && rect($0).maxX <= width
            }) else { throw failure("Unselect must remain fully visible beside the capsule at width \(width)") }
            print("SELECTION width=\(width) viewport=\(viewport) unselect=\(rect(trailing))")
            if let directory = ProcessInfo.processInfo.environment["LOGSEQ_LAYOUT_SCREENSHOTS"] {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try image.pngData()?.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("logseq-selection-capsule-\(Int(width)).png"))
            }

        }
        print("PASS: five selection actions fit in the native capsule with Unselect pinned separately at phone and tablet widths")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SelectionToolbarLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
