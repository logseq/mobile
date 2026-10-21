import UIKit
import SwiftUI
@testable import LUIAppleBackend
@testable import Logseq
import LogseqModel

@main struct ContinuousQuickCaptureCheck {
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
        func focusedInput(_ view: UIView) -> UIView? {
            if view.isFirstResponder, view is UITextField || view is UITextView { return view }
            return view.subviews.lazy.compactMap(focusedInput).first
        }
        try await Task.sleep(for: .milliseconds(400))
        try backend.performPress(node: find { $0.property(.accessibilityIdentifier)?.stringValue == "button.composer.expand" })
        try await Task.sleep(for: .milliseconds(800))
        guard let initialInput = focusedInput(window) else { throw failure("Capture must initially own the keyboard") }
        var field = initialInput
        var hideEvents = 0
        let observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { hideEvents += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for text in ["First capture", "Second capture"] {
            (field as? UIKeyInput)?.insertText(text)
            await runtime.drainEffectsForTesting()
            try await Task.sleep(for: .milliseconds(250))
            try backend.performPress(node: find { $0.property(.accessibilityIdentifier)?.stringValue == "button.send" })
            await runtime.drainEffectsForTesting()
            try await Task.sleep(for: .milliseconds(500))
            guard let current = focusedInput(window), current === initialInput, hideEvents == 0 else {
                throw failure("Submitting quick capture must preserve the focused native input")
            }
            field = current
            let text = (field as? UITextField)?.text ?? (field as? UITextView)?.text ?? ""
            guard text.isEmpty else { throw failure("Only the submitted draft should be cleared") }
            _ = try find { $0.property(.accessibilityIdentifier)?.stringValue == "capture.confirmation.icon" }
        }
        (field as? UIKeyInput)?.insertText("Next draft")
        await runtime.drainEffectsForTesting()
        try await Task.sleep(for: .seconds(3))
        guard focusedInput(window) === initialInput, hideEvents == 0 else {
            throw failure("Dismissing the confirmation must preserve the keyboard")
        }
        let nextDraft = (field as? UITextField)?.text ?? (field as? UITextView)?.text ?? ""
        guard nextDraft == "Next draft" else { throw failure("The next draft must remain editable") }
        print("PASS: consecutive captures and confirmation dismissal preserve the native input and keyboard")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "ContinuousQuickCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
