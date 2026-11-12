import Darwin
import SwiftUI
import UIKit
@testable import Logseq

private struct AppearanceCheckRoot: View {
    let renderer: LGRenderer
    @AppStorage("logseq.appearance") private var appearance = "system"
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        LGRendererRoot(renderer: renderer)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            .tint(LogseqThemePolicy.accent)
            .foregroundStyle(palette.primaryText)
            .background(palette.background.ignoresSafeArea())
    }
    private var palette: LogseqThemePalette {
        LogseqThemePolicy.palette(mode: LogseqThemeMode(rawValue: appearance) ?? .system,
                                  systemIsDark: colorScheme == .dark)
    }
}

@main struct DuoAppearanceResponsivenessCheck {
    @MainActor static func main() async throws {
        let rows: [[String: Any]] = (0..<150).map { index in
            ["depth": 0, "block": ["uuid": "row-\(index)", "title": "Journal text \(index) with enough content to scroll", "pageId": "journal"]]
        }
        let snapshot = String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": [
            "graphName": "Appearance responsiveness", "selectedGraphId": "appearance-check", "outlinerRows": rows
        ]]), as: UTF8.self)
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { _ in snapshot }))
        try runtime.applyCoreResponse(snapshot)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        if ProcessInfo.processInfo.environment["LOGSEQ_DUO_REGULAR_WIDTH"] == "1" {
            window.traitOverrides.horizontalSizeClass = .regular
        }
        let host = UIHostingController(rootView: AppearanceCheckRoot(renderer: runtime.renderer))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func cpuTime() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        try await Task.sleep(for: .seconds(1))
        guard let journal = views(window).compactMap({ $0 as? UIScrollView }).first(where: {
            $0.contentSize.height > $0.bounds.height * 2 && $0.bounds.width > 100
        }) else { throw failure("Journal must mount") }
        for (index, mode) in ["dark", "light", "dark", "system", "dark"].enumerated() {
            UserDefaults.standard.set(mode, forKey: "logseq.appearance")
            try runtime.applyHostUpdate(kind: "settings", payload:
                "{\"appearance\":\"\(mode)\",\"language\":\"system\",\"spellCheck\":true,\"autoCorrection\":true,\"taskRemindersEnabled\":false,\"taskRemindersStatus\":\"\",\"sidebarTabs\":[],\"baseURL\":\"https://api.logseq.io\",\"version\":\"check\",\"revision\":\"check\"}")
            let orientation: UIInterfaceOrientation = index.isMultiple(of: 2) ? .landscapeRight : .portrait
            let mask: UIInterfaceOrientationMask = index.isMultiple(of: 2) ? .landscapeRight : .portrait
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                print("ROTATION_REQUEST_ERROR: \(error)")
            }
            for _ in 0..<100 {
                if scene.interfaceOrientation == orientation { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard scene.interfaceOrientation == orientation else { throw failure("Duo must rotate to exercise toolbar layout changes") }
            guard window.isKeyWindow, journal.window === window else {
                throw failure("The responsiveness check must exercise the visible journal")
            }
            // Exercise scrolling while the bar's automatic luminance is changing.
            for step in 0..<12 {
                journal.setContentOffset(CGPoint(x: 0, y: index * 240 + step * 45), animated: false)
                try await Task.sleep(for: .milliseconds(30))
            }
            try await Task.sleep(for: .milliseconds(500))
            if #available(iOS 26.0, *) {
                guard journal.topEdgeEffect.isHidden else {
                    throw failure("Duo must disable the top-edge effect implicated in the observed luminance/layout loop")
                }
            }
            let start = Date()
            let cpu = cpuTime()
            try await Task.sleep(for: .milliseconds(1200))
            let elapsed = Date().timeIntervalSince(start)
            let ratio = (cpuTime() - cpu) / elapsed
            print("APPEARANCE_IDLE mode=\(mode) cpu=\(ratio) delay=\(elapsed)")
            guard elapsed < 2.2, ratio < 0.5 else {
                throw failure("Theme changes must settle without starving input or spinning in layout: mode=\(mode), CPU=\(ratio), delay=\(elapsed)")
            }
        }
        print("PASS: repeated appearance changes and journal scrolling settle without a main-thread layout loop")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "DuoAppearanceResponsiveness", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
