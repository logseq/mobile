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
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
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
        for width in [CGFloat(320), CGFloat(393)] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: scene.screen.bounds.height)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(900))
            let toolbar = try model("toolbar.outliner.selection")
            guard toolbar.property(.placement) == nil, toolbar.property(.background) == nil else {
                throw failure("The selection toolbar must be inline without a capsule background")
            }
            let unselect = try model("button.outliner.selection.unselect")
            print("SELECTION width=\(width) window=\(window.bounds) unselect=\(String(describing: frames[unselect.id]))")
            guard let unselectFrame = frames[unselect.id], unselectFrame.maxX <= width else {
                throw failure("Unselect must remain fully visible at width \(width)")
            }
            for name in ["copy", "outdent", "indent", "delete", "copyReference"] {
                let button = try model("button.outliner.selection." + name)
                guard let frame = frames[button.id], frame.minX >= 0, frame.maxX <= unselectFrame.minX + 0.5,
                    frame.width >= 44, frame.height >= 44 else {
                    throw failure("Five full-size actions must fit before Unselect at width \(width): \(name)")
                }
                print("SELECTION width=\(width) action=\(name) frame=\(frame)")
            }
        }
        print("PASS: five selection actions fit with Unselect at narrow and regular widths, without a capsule background")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SelectionToolbarLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
