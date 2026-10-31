import SwiftUI
import UIKit
import LogseqModel
@testable import LUIAppleBackend
@testable import Logseq

@main struct SyncAuthenticationCheck {
    @MainActor static func main() async throws {
        var signIns = 0
        let handler = LGPlatformEffectHandler(
            saveSettings: { _ in }, runtimeLog: LogseqRuntimeLog(capacity: 1),
            copyText: { _ in },
            signIn: { signIns += 1; return "Sign-in cancelled for testing" },
            signOut: {}
        )
        let runtime = LGRuntime(native: LGCoreNativeCaller(),
            effectExecutor: LGCoreEffectExecutor(platformEffect: { await handler.execute($0) }))
        try runtime.applyCoreResponse(#"{"ok":true,"result":{"blocks":[],"selectedGraphId":"local","graphName":"Local","syncConnected":false,"outlinerRows":[]}}"#)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 1)
        try runtime.applyHostUpdate(kind: "local-graph-ids", payload: #"["local"]"#)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        let backend = runtime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func press(_ identifier: String) async throws {
            guard let id = find(identifier) else { throw failure("Missing control: " + identifier) }
            try backend.performPress(node: id)
            await runtime.drainEffectsForTesting()
            try await Task.sleep(for: .milliseconds(250))
        }
        try await Task.sleep(for: .milliseconds(500))
        guard let indicator = find("sync.disconnected"),
              backend.model(id: indicator)?.property(.foreground)?.stringValue == "muted-foreground" else {
            throw failure("Signed-out sync indicator must be gray")
        }
        try await press("sync.disconnected")
        guard signIns == 1, find("sheet.sync-status") == nil else {
            throw failure("The signed-out indicator must open Hosted UI directly")
        }
        try runtime.applyHostUpdate(kind: "authentication", payload: #"{"state":"signedIn","errorMessage":null}"#)
        try await Task.sleep(for: .milliseconds(150))
        try await press("sync.disconnected")
        guard let syncNow = find("button.sync-now"), backend.model(id: syncNow)?.property(.enabled)?.boolValue != false else {
            throw failure("Signed-in users must be able to sync")
        }
        try runtime.applyHostUpdate(kind: "authentication", payload: #"{"state":"signedOut","errorMessage":"Sign in to connect to Logseq Sync."}"#)
        try await Task.sleep(for: .milliseconds(400))
        guard let disabled = find("button.sync-now"), backend.model(id: disabled)?.property(.enabled)?.boolValue == false,
              let prompt = find("sync.authentication-error"),
              backend.model(id: prompt)?.property(.text)?.stringValue == "Sign in to connect to Logseq Sync.",
              find("button.sync-sign-in") != nil else {
            throw failure("Failed refresh must disable sync and present the login prompt")
        }
        for appearance in ["light", "dark"] {
            try runtime.applyHostUpdate(kind: "settings", payload: "{\"appearance\":\"\(appearance)\"}")
            window.overrideUserInterfaceStyle = appearance == "dark" ? .dark : .light
            try await Task.sleep(for: .milliseconds(300))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("sync-authentication-\(appearance).png"))
        }
        try await press("button.sync-sign-in")
        guard signIns == 2, find("sheet.sync-status") == nil else {
            throw failure("The refresh-failure prompt must lead to Hosted UI")
        }
        print("PASS: signed-out sync is gray, indicator opens login, failed refresh disables Sync now and offers sign-in")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SyncAuthentication", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
