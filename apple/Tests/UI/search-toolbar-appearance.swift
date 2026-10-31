import SwiftUI
import UIKit
@testable import Logseq
@testable import LUIAppleBackend

@main struct SearchToolbarAppearanceCheck {
    @MainActor static func main() async throws {
        let snapshot = #"{"ok":true,"result":{"graphName":"Work","selectedGraphId":"work","outlinerRows":[]}}"#
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { _ in snapshot }))
        try runtime.applyCoreResponse(snapshot)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        defer { runtime.stop() }
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func node(_ identifier: String) throws -> Int {
            guard let id = backend.rootIDs.flatMap(descendants).first(where: {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }) else { throw failure("Missing " + identifier) }
            return id
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let composerID = try node("surface.composer.root")
        let searchID = try node("button.search")
        for _ in 0..<100 {
            if frames[composerID] != nil && frames[searchID] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let composer = frames[composerID], let search = frames[searchID] else {
            throw failure("Missing rendered bottom controls")
        }
        print("BOTTOM_CHROME composer=\(composer) search=\(search)")
        guard abs(composer.height - 58) <= 1, abs(search.height - 58) <= 1,
              abs(search.width - 58) <= 1, abs(composer.midY - search.midY) <= 1,
              abs(composer.minX - 16) <= 1, abs(window.bounds.width - search.maxX - 16) <= 1,
              abs(search.minX - composer.maxX - 10) <= 1 else {
            throw failure("Capture and search must retain matching 58-point controls, symmetric 16-point insets, and their 10-point gap")
        }
        func controllers(_ c: UIViewController) -> [UIViewController] { [c] + c.children.flatMap(controllers) }
        guard let navigation = controllers(window.rootViewController!).compactMap({ $0 as? UINavigationController }).first,
              navigation.isToolbarHidden else {
            throw failure("An inactive search must not add a system toolbar background behind the floating controls")
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try image.pngData()!.write(to: URL.documentsDirectory.appending(path: "search-toolbar-appearance.png"))
        print("PASS: floating composer/search controls retain their size, spacing, and transparent surrounding area")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SearchToolbarAppearance", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
