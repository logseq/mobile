import UIKit
import SwiftUI
@testable import LUIAppleBackend
@testable import Logseq

@main struct ChromeAlignmentCheck {
    @MainActor static func main() async throws {
        let snapshot = #"{"ok":true,"result":{"revision":1,"graphName":"Work","selectedGraphId":"work","graphs":[{"id":"work","name":"Work","isReady":true,"isEncrypted":false}],"blocks":[],"outlinerRows":[],"outlinerState":{"selectedBlockIds":[]}}}"#
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
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(800))
        func nodeIDs(_ node: Int) -> [Int] {
            [node] + (backend.model(id: node)?.children ?? backend.extensionModel(id: node)?.children ?? []).flatMap(nodeIDs)
        }
        func id(_ identifier: String) throws -> Int {
            guard let node = backend.rootIDs.flatMap(nodeIDs).first(where: {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }) else { throw failure("Missing layout frame: " + identifier) }
            return node
        }
        func frame(_ identifier: String) throws -> CGRect {
            guard let result = frames[try id(identifier)] else { throw failure("Missing frame: " + identifier) }
            return result
        }
        var errors: [String] = []
        try backend.performPress(node: id("button.composer.expand"))
        try await Task.sleep(for: .milliseconds(800))
        let controls = try frame("row.composer.controls")
        for identifier in ["button.attachment", "button.task-status", "button.send"] {
            let control = try frame(identifier)
            print("CHROME \(identifier) frame=\(control) footer=\(controls)")
            if abs(control.midY - controls.midY) > 0.5 {
                errors.append(identifier + " is not vertically centered in the composer footer")
            }
            if identifier != "button.send", abs(control.height - controls.height) > 0.5 {
                errors.append(identifier + " does not use the full centered footer touch cell")
            }
        }
        try backend.performPress(node: id("button.sidebar"))
        try await Task.sleep(for: .milliseconds(1500))
        let settings = try frame("button.sidebar.settings")
        let sidebar = try frame("sidebar.navigation")
        let journals = try frame("link.sidebar.journals")
        let toolbar = try frame("button.sidebar")
        let safeBottom = window.bounds.maxY - window.safeAreaInsets.bottom
        print("CHROME sidebar=\(sidebar) journals=\(journals) toolbar=\(toolbar) settings=\(settings) safeBottom=\(safeBottom)")
        if journals.minY <= toolbar.maxY {
            errors.append("Journals must start below the navigation header")
        }
        if abs(sidebar.maxX - settings.maxX - 16) > 1 || abs(safeBottom - settings.maxY) > 1
            || settings.width < 44 || settings.height < 44 {
            errors.append("Settings must sit at the sidebar's bottom trailing corner above the home indicator")
        }
        try backend.performPress(node: id("button.sidebar.settings"))
        try await Task.sleep(for: .milliseconds(300))
        _ = try id("sheet.settings")
        guard errors.isEmpty else { throw failure(errors.joined(separator: "; ")) }
        print("PASS: native composer controls are aligned and the sidebar footer opens Settings")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "ChromeAlignmentCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
