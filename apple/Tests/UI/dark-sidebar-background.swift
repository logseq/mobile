import UIKit
import SwiftUI
@testable import LUIAppleBackend
@testable import Logseq

@main struct DarkSidebarBackgroundCheck {
    @MainActor static func main() async throws {
        let previous = UserDefaults.standard.object(forKey: "logseq.appearance")
        UserDefaults.standard.set("dark", forKey: "logseq.appearance")
        defer { UserDefaults.standard.set(previous, forKey: "logseq.appearance") }
        let snapshot = #"{"ok":true,"result":{"graphName":"Work","selectedGraphId":"work","outlinerRows":[],"outlinerState":{"selectedBlockIds":[]}}}"#
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { _ in snapshot }))
        try runtime.applyCoreResponse(snapshot)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        guard let toggle = backend.rootIDs.flatMap(descendants).first(where: {
            backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == "button.sidebar"
        }) else { throw failure("Missing sidebar toggle") }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; runtime.stop() }
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer)
            .preferredColorScheme(.dark)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(700))
        try backend.performPress(node: toggle)
        try await Task.sleep(for: .milliseconds(700))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }.cgImage!
        let bytes = image.dataProvider!.data! as Data
        let x = 10, y = Int(window.bounds.height * 0.65)
        let offset = y * image.bytesPerRow + x * image.bitsPerPixel / 8
        let pixel = Array(bytes[offset..<offset + 4])
        print("SIDEBAR_PIXEL \(pixel)")
        // UIGraphics uses BGRA on iOS; compare against the app's dark background.
        guard abs(Int(pixel[0]) - 56) <= 2, abs(Int(pixel[1]) - 45) <= 2,
              Int(pixel[2]) <= 2 else { throw failure("Sidebar must use Logseq's dark palette instead of the system navigation background") }
        print("PASS: the native sidebar uses the Logseq dark background")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "DarkSidebarBackground", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
