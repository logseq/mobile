import UIKit
import SwiftUI
import LUIAppleBackend

@main struct DrawerRenderingCheck {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(DrawerRenderingDelegate.self))
    }
}

@MainActor final class RenderCounter {
    var bodies = 0
    var displayedRevision = 0
}

private struct ContentRow: View {
    @Environment(\.isScrollEnabled) private var isScrollEnabled
    let index: Int
    let counter: RenderCounter
    let revision: Int

    var body: some View {
        counter.bodies += 1
        counter.displayedRevision = revision
        let _ = isScrollEnabled
        return Text("Long page block \(index), revision \(revision)").frame(height: 32)
    }
}

@MainActor final class DrawerRenderingDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task {
            do { try await run() }
            catch { finish("FAIL: \(error)") }
        }
        return true
    }

    func finish(_ output: String) {
        try? output.write(to: URL.documentsDirectory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }

    func run() async throws {
        let counter = RenderCounter()
        let registry = LUIAppleExtensionRegistry()
        try registry.register(LUIAppleExtension(identifier: "long-content", fingerprint: "long-content-v1", properties: [.init(name: "revision", kind: .int)]) { context in
            let revision: Int
            if case .int(let value) = context.property("revision") { revision = value } else { revision = 0 }
            return AnyView(ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<300, id: \.self) { ContentRow(index: $0, counter: counter, revision: revision) }
                }
            })
        })
        try registry.register(LUIAppleExtension(identifier: "sidebar-content", fingerprint: "sidebar-content-v1") { _ in
            AnyView(ScrollView { Text("Sidebar").frame(height: 3_000) })
        })
        let backend = try LUIAppleBackend(extensionRegistry: registry)
        try backend.apply(json: """
        {"generation":1,"ops":[
          {"op":"create-node","id":1,"kind":"root"},
          {"op":"create-node","id":2,"kind":"drawer"},
          {"op":"create-extension","id":3,"identifier":"long-content","fingerprint":"long-content-v1"},
          {"op":"create-extension","id":4,"identifier":"sidebar-content","fingerprint":"sidebar-content-v1"},
          {"op":"insert-child","parent":1,"child":2,"index":0},
          {"op":"insert-child","parent":2,"child":3,"index":0},
          {"op":"insert-child","parent":2,"child":4,"index":1}
        ]}
        """)
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        window.rootViewController = UIHostingController(rootView: LUISwiftUIRoot(backend: backend, rootID: 1))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(600))
        guard counter.bodies == 300 else { finish("FAIL: expected 300 mounted rows, got \(counter.bodies)"); return }
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scrolls = scrollViews(window).filter { $0.contentSize.height > $0.bounds.height }
        guard scrolls.count == 2 else { finish("FAIL: missing drawer scroll views"); return }
        for (index, scroll) in scrolls.enumerated() {
            scroll.setContentOffset(CGPoint(x: 0, y: (index + 1) * 600), animated: false)
        }
        try await Task.sleep(for: .milliseconds(200))
        let offsets = scrolls.map(\.contentOffset)
        let mountedBodies = counter.bodies
        for (index, selected) in [true, false, true, false].enumerated() {
            try backend.apply(json: """
            {"generation":\(index + 2),"ops":[{"op":"set-prop","id":2,"property":"selected","value":\(selected)}]}
            """)
            try await Task.sleep(for: .milliseconds(80))
            let panes = scrollViews(window).filter { $0.contentSize.height > $0.bounds.height }
            guard panes.count == 2, panes.allSatisfy({ !$0.isScrollEnabled && !$0.showsVerticalScrollIndicator && !$0.showsHorizontalScrollIndicator }) else {
                finish("FAIL: both drawer panes must stop scrolling and hide indicators during transitions"); return
            }
            try await Task.sleep(for: .milliseconds(420))
        }
        let repeatedBodies = counter.bodies - mountedBodies
        guard repeatedBodies == 0 else {
            finish("FAIL: drawer transitions reevaluated \(repeatedBodies) content rows")
            return
        }
        guard zip(scrolls, offsets).allSatisfy({ scroll, offset in
            scrollViews(window).contains(where: { $0 === scroll })
                && scroll.contentOffset == offset && scroll.isScrollEnabled
        }) else {
            finish("FAIL: drawer transitions changed scroll identity, offset, or availability: \(scrolls.map(\.contentOffset)) expected \(offsets)"); return
        }
        try backend.apply(json: """
        {"generation":6,"ops":[{"op":"set-extension-prop","id":3,"property":"revision","value":1}]}
        """)
        try await Task.sleep(for: .milliseconds(300))
        guard counter.displayedRevision == 1, counter.bodies > mountedBodies else {
            finish("FAIL: content updates stopped rendering after drawer transitions"); return
        }
        finish("PASS: four drawer transitions preserved all 300 content rows without reevaluation; content updates still render")
    }
}
