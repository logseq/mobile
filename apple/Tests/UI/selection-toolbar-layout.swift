import UIKit
import SwiftUI
@testable import LUIAppleBackend
@testable import Logseq

@main struct SelectionToolbarLayoutCheck {
    @MainActor static func main() async throws {
        let snapshot = #"{"ok":true,"result":{"graphName":"Work","selectedGraphId":"work","outlinerRows":[{"block":{"uuid":"selected","title":"Selected block","pageId":"page"},"depth":0}],"outlinerState":{"selectedBlockIds":["selected"],"selectedTaskBlockIds":["selected"]}}}"#
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
            for action in ["copy", "tag", "status", "scheduled", "deadline", "outdent", "indent", "moveUp", "moveDown", "done"] {
                _ = try model("button.outliner.selection." + action)
            }
            func descendants(_ view: UIView) -> [UIView] {
                [view] + view.subviews.flatMap(descendants)
            }
            func rect(_ view: UIView) -> CGRect { view.convert(view.bounds, to: window) }
            let views = descendants(window)
            guard let overflow = views.compactMap({ $0 as? UIButton }).first(where: {
                $0.accessibilityIdentifier == "button.outliner.selection.more" && !$0.isHidden && $0.window === window
            }), overflow.showsMenuAsPrimaryAction, overflow.menu?.children.count == 5 else {
                throw failure("The native selection overflow must expose all five menu actions")
            }
            let overflowFrame = rect(overflow)
            guard window.bounds.insetBy(dx: -1, dy: -1).contains(overflowFrame),
                  overflowFrame.width >= 44, overflowFrame.height >= 44 else {
                throw failure("The selection overflow needs a full tap target inside the window: \(overflowFrame)")
            }
            let scrollViews = views.compactMap { $0 as? UIScrollView }
            guard let scroll = scrollViews.first(where: {
                (44...80).contains(rect($0).height) && rect($0).minY > window.bounds.height - 120
            }) else {
                throw failure("Missing selection scroll viewport for \(window.bounds). Scroll frames: \(scrollViews.map(rect))")
            }
            let viewport = rect(scroll)
            let actionsWidth: CGFloat = 9 * 44
            let allowedWidth = overflowFrame.minX - viewport.minX - 12
            guard abs(viewport.width - min(actionsWidth, allowedWidth)) < 1,
                  abs(scroll.contentSize.width - actionsWidth) < 1 else {
                throw failure("Selection viewport at width \(width) must fit the actions or allow horizontal scrolling: \(viewport)")
            }
            print("SELECTION width=\(width) viewport=\(viewport), content=\(scroll.contentSize.width)")
            if let directory = ProcessInfo.processInfo.environment["LOGSEQ_LAYOUT_SCREENSHOTS"] {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try image.pngData()?.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("logseq-selection-capsule-\(Int(width)).png"))
            }

        }
        print("PASS: selection capsule fits its actions on wide screens and scrolls at phone widths")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SelectionToolbarLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
