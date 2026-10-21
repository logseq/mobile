import UIKit
import SwiftUI
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class IndentationEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct OutlinerSaveIndentationCheck {
    @MainActor static func main() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: IndentationEffects())
        let snapshot = #"{"ok":true,"result":{"graphName":"Lambda","selectedGraphId":"lambda","outlinerRows":[{"depth":0,"hasChildren":true,"block":{"uuid":"parent","title":"Problems","pageId":"page"}},{"depth":1,"hasChildren":true,"block":{"uuid":"group","title":"Block","pageId":"page"}},{"depth":2,"block":{"uuid":"editing","title":"The text","pageId":"page"}}],"outlinerState":{"editing":{"uuid":"editing","title":"The text","caretUTF16Offset":8},"selectedBlockIds":[]}}}"#
        try runtime.applyCoreResponse(snapshot)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func editor() throws -> UITextView {
            guard let view = descendants(host.view).compactMap({ $0 as? UITextView }).first(where: { $0.text.hasPrefix("The text") }) else {
                throw failure("Missing native nested editor")
            }
            return view
        }
        func screenshot(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try image.pngData()!.write(to: documents.appendingPathComponent(name + ".png"))
        }
        try await Task.sleep(for: .milliseconds(700))
        let original = try editor()
        let initialX = original.convert(.zero, to: window).x
        try screenshot("indentation-before-save")
        // Content-only save replies do not include hierarchy metadata.
        try runtime.applyCoreResponse(#"{"ok":true,"result":{"isOutlinerPatch":true,"outlinerRows":[],"blocks":[{"uuid":"editing","title":"The text saved","pageId":"page"}],"outlinerState":{"editing":{"uuid":"editing","title":"The text saved","caretUTF16Offset":14},"selectedBlockIds":[]}}}"#)
        var positions: [CGFloat] = []
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(16))
            host.view.layoutIfNeeded()
            positions.append(try editor().convert(.zero, to: window).x)
        }
        try screenshot("indentation-after-save")
        guard positions.allSatisfy({ abs($0 - initialX) < 1 }) else {
            throw failure("Saving a nested block moved its editor: initial x=\(initialX), subsequent x=\(positions)")
        }
        guard try editor() === original, try editor().text == "The text saved" else {
            throw failure("Saving must retain the editor and refresh its text")
        }
        print("PASS: nested editor remains at x=\(initialX) through all 24 frames after a content save")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "OutlinerSaveIndentation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
