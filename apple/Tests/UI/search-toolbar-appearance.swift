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
        let tabsID = try node("group.bottom.tabs")
        let chromeID = try node("row.bottom.capture")
        let actionsID = try node("group.bottom.actions")
        let searchID = try node("button.search")
        let captureID = try node("button.composer.expand")
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func tabsFrame() -> CGRect? {
            if #available(iOS 26, *) {
                guard let bar = views(window).compactMap({ $0 as? UITabBar }).first,
                      bar.items?.map(\.accessibilityIdentifier) == ["tab.bottom.home", "tab.bottom.tasks", "tab.bottom.flashcards"]
                else { return nil }
                return bar.convert(bar.bounds, to: window)
            }
            return frames[tabsID]
        }
        for _ in 0..<100 {
            if tabsFrame() != nil, [chromeID, actionsID, searchID, captureID].allSatisfy({ frames[$0] != nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let tabs = tabsFrame(), let actions = frames[actionsID],
              let chrome = frames[chromeID],
              let search = frames[searchID], let capture = frames[captureID] else {
            throw failure("Missing rendered bottom controls")
        }
        print("BOTTOM_CHROME tabs=\(tabs) actions=\(actions) search=\(search) capture=\(capture)")
        // The native tab bar's view includes the margins around its floating items.
        guard tabs.height >= 44, abs(actions.height - 58) <= 1,
              abs(search.midY - capture.midY) <= 1, tabs.minY <= chrome.midY, tabs.maxY >= chrome.midY,
              tabs.minX <= chrome.minX + 1, abs(window.bounds.width - actions.maxX - 16) <= 1,
              tabs.maxX < actions.minX, actions.contains(search), actions.contains(capture),
              search.maxX <= capture.minX else {
            throw failure("The tab and action groups must be aligned at opposite edges with Search before Capture")
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
        print("PASS: the floating tab and action groups keep their alignment and transparent surrounding area")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SearchToolbarAppearance", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
