import UIKit
import SwiftUI
@testable import LUIAppleBackend
@testable import Logseq
import LogseqModel

@main struct CaptureConfirmationPositionCheck {
    @MainActor static func main() async throws {
        let snapshot = #"{"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],"graphName":"Work","selectedGraphId":"work","outlinerRows":[],"outlinerState":{"selectedBlockIds":[]}}}"#
        let platform = LGPlatformEffectHandler(saveSettings: { _ in },
            runtimeLog: LogseqRuntimeLog(capacity: 1), copyText: { _ in }, signOut: {})
        let executor = LGCoreEffectExecutor(callCore: { _ in snapshot },
            platformEffect: { await platform.execute($0) })
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: executor)
        try runtime.applyCoreResponse(snapshot)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ matches: (LUINodeModel) -> Bool) throws -> Int {
            guard let id = backend.rootIDs.flatMap(descendants).first(where: {
                backend.model(id: $0).map(matches) ?? false
            }) else { throw failure("Missing capture control") }
            return id
        }
        try await Task.sleep(for: .milliseconds(400))
        try backend.performPress(node: find { $0.property(.accessibilityIdentifier)?.stringValue == "button.composer.expand" })
        try await Task.sleep(for: .milliseconds(800))
        try backend.performTextChange(node: find { $0.property(.styleClass)?.stringValue == "composer-input" }, text: "Remember this")
        await runtime.drainEffectsForTesting()
        try await Task.sleep(for: .milliseconds(500))
        try backend.performPress(node: find { $0.property(.accessibilityIdentifier)?.stringValue == "button.send" })
        await runtime.drainEffectsForTesting()
        try await Task.sleep(for: .milliseconds(500))
        let toast = try find { $0.kind == .toast }
        guard let frame = frames[toast] else { throw failure("Missing confirmation frame") }
        print("CAPTURE_CONFIRMATION frame=\(frame) safeTop=\(window.safeAreaInsets.top)")
        let icon = try? find { $0.property(.accessibilityIdentifier)?.stringValue == "capture.confirmation.icon"
            && $0.property(.text)?.stringValue == "✅" }
        guard icon != nil, frame.minY >= window.safeAreaInsets.top,
              frame.maxY < window.safeAreaInsets.top + 150 else {
            throw failure("Capture confirmation must show a check icon at the top safe area")
        }
        print("PASS: successful capture shows its check icon at the top")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "CaptureConfirmationPosition", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
