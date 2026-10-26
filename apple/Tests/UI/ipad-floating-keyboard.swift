import SwiftUI
import UIKit
@testable import Logseq
@testable import LUIAppleBackend

@MainActor private final class FloatingKeyboardEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        .init(succeeded: true, message: "", output: .discard)
    }
}

@MainActor private final class KeyboardFrameSamples {
    var frames: [CGRect] = []
}

// Run on iPad, then use the Simulator keyboard controls to float and move the keyboard.
@main struct IPadFloatingKeyboardCheck {
    @MainActor static func main() async throws {
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: FloatingKeyboardEffects())
        try runtime.applyCoreResponse(#"{"ok":true,"result":{"selectedGraphId":"demo","graphName":"Keyboard regression","selectedPage":{"uuid":"page","title":"Keyboard regression"},"outlinerRows":[{"depth":0,"block":{"uuid":"editor","title":"Keyboard test","pageId":"page","markup":[{"type":"text","text":"Keyboard test"}]}}],"outlinerState":{"editing":{"uuid":"editor","title":"Keyboard test","caretUTF16Offset":13}}}}"#)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
        let samples = KeyboardFrameSamples()
        let observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidChangeFrameNotification,
            object: nil, queue: .main) { notification in
            let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { if let frame { samples.frames.append(frame) } }
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer {
            NotificationCenter.default.removeObserver(observer)
            runtime.stop(); window.isHidden = true; window.rootViewController = nil
        }
        func nodes(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(nodes)
        }
        var processed = 0
        var floatingCount = 0
        var firstFloatingBar: CGRect?
        if ProcessInfo.processInfo.environment["LOGSEQ_KEYBOARD_CHECK_MODE"] == "docked" {
            for _ in 0..<100 where samples.frames.last?.height ?? 0 < 80 {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .milliseconds(400))
            func toolbarFrame() throws -> CGRect {
                guard let id = backend.rootIDs.flatMap(nodes).first(where: {
                    backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == "toolbar.outliner.editor"
                }), let frame = frames[id] else { throw failure("Missing editor toolbar") }
                return frame
            }
            guard let keyboard = samples.frames.last, keyboard.height > 80,
                  abs(try toolbarFrame().maxY - keyboard.minY) < 24 else {
                throw failure("The docked keyboard must keep the editor toolbar above it: keyboard=\(String(describing: samples.frames.last)) toolbar=\(String(describing: try? toolbarFrame()))")
            }
            window.endEditing(true)
            try await Task.sleep(for: .milliseconds(800))
            guard try toolbarFrame().maxY >= window.bounds.maxY - window.safeAreaInsets.bottom - 24 else {
                throw failure("Hiding the keyboard must return the editor toolbar to the bottom")
            }
            print("PASS: docked and dismissed keyboards preserve the editor toolbar position")
            return
        }
        print("READY: float the iPad software keyboard and move it twice")
        for _ in 0..<3600 {
            try await Task.sleep(for: .milliseconds(100))
            guard processed < samples.frames.count else { continue }
            let keyboard = samples.frames[processed]; processed += 1
            guard keyboard.width > 0, keyboard.height > 80, keyboard.width < window.bounds.width * 0.8 else { continue }
            try await Task.sleep(for: .milliseconds(300))
            guard let id = backend.rootIDs.flatMap(nodes).first(where: {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == "toolbar.outliner.editor"
            }), let toolbar = frames[id] else { throw failure("The editor toolbar must stay mounted with a floating keyboard") }
            guard toolbar.maxY >= window.bounds.maxY - window.safeAreaInsets.bottom - 24,
                  toolbar.maxY <= window.bounds.maxY else {
                throw failure("Floating keyboards must not move the toolbar away from the bottom: keyboard=\(keyboard), toolbar=\(toolbar), window=\(window.bounds)")
            }
            if let firstFloatingBar, abs(firstFloatingBar.minY - toolbar.minY) > 1 {
                throw failure("Moving a floating keyboard moved the action bar")
            }
            firstFloatingBar = toolbar; floatingCount += 1
            if floatingCount >= 2 {
                print("PASS: floating keyboard movement preserves the bottom action bar position")
                return
            }
        }
        throw failure("Move the floating keyboard twice to complete the native interaction check")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "IPadFloatingKeyboard", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
