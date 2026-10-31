import UIKit
import SwiftUI
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class SearchDismissLayoutProbe {
    var homeFrame = CGRect.zero
    var homeBaseline = CGRect.zero
    var keyboardAnimationDuration: TimeInterval?
}

@main struct SearchDismissLayoutCheck {
    @MainActor static func main() async throws {
        try await check("")
        try await check("Needle")
    }

    @MainActor static func check(_ initialQuery: String) async throws {
        let probe = SearchDismissLayoutProbe()
        let registry = LUIAppleExtensionRegistry()
        try LGSearchPresentationExtension.register(in: registry)
        try LGNavigationExtension.register(in: registry)
        try registry.register(LUIAppleExtension(identifier: "search-layout-probe", fingerprint: "search-layout-probe", properties: []) { _ in
            AnyView(VStack {
                Text("Search your graph").font(.headline)
                Text("Find pages and blocks by title or content.")
            }.foregroundStyle(.blue).frame(maxWidth: .infinity, maxHeight: .infinity))
        })
        try registry.register(LUIAppleExtension(identifier: "search-home-probe", fingerprint: "search-home-probe", properties: []) { _ in
            AnyView(VStack {
                Text("Home")
                Spacer()
                TextField("Capture", text: .constant(""))
                    .accessibilityIdentifier("search-home.capture")
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.red)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    probe.homeFrame = frame
                })
        })
        try registry.register(LUIAppleExtension(identifier: "search-topbar-probe", fingerprint: "search-topbar-probe", properties: []) { _ in
            AnyView(Button {} label: {
                Rectangle().fill(Color.green).frame(width: 24, height: 24)
            })
        })
        let backend = try LUIAppleBackend(extensionRegistry: registry)
        var generation = 1
        try backend.apply(json: """
        {"generation":1,"ops":[
        {"op":"create-extension","id":1,"identifier":"native-search-presentation","fingerprint":"\(LGSearchPresentationExtension.fingerprint)"},
        {"op":"set-extension-prop","id":1,"property":"presented","value":false},
        {"op":"set-extension-prop","id":1,"property":"bottom-occupies-layout-space","value":false},
        {"op":"set-extension-prop","id":1,"property":"depth","value":0},
        {"op":"set-extension-prop","id":1,"property":"query","value":"\(initialQuery)"},
        {"op":"set-extension-prop","id":1,"property":"title","value":"Search"},
        {"op":"create-node","id":2,"kind":"column"},
        {"op":"set-prop","id":2,"property":"grow","value":1.0},
        {"op":"create-extension","id":6,"identifier":"native-navigation-stack","fingerprint":"\(LGNavigationExtension.fingerprint)"},
        {"op":"set-extension-prop","id":6,"property":"depth","value":0},
        {"op":"set-extension-prop","id":6,"property":"back-depth","value":0},
        {"op":"set-extension-prop","id":6,"property":"bottom-occupies-layout-space","value":false},
        {"op":"set-extension-prop","id":6,"property":"composer-dismissal-enabled","value":false},
        {"op":"set-extension-prop","id":6,"property":"title","value":"Home"},
        {"op":"create-node","id":7,"kind":"column"},
        {"op":"set-prop","id":7,"property":"grow","value":1.0},
        {"op":"insert-child","parent":6,"child":7,"index":0},
        {"op":"create-node","id":8,"kind":"column"},
        {"op":"create-extension","id":13,"identifier":"search-topbar-probe","fingerprint":"search-topbar-probe"},
        {"op":"insert-child","parent":8,"child":13,"index":0},
        {"op":"insert-child","parent":6,"child":8,"index":1},
        {"op":"create-node","id":9,"kind":"column"},
        {"op":"insert-child","parent":6,"child":9,"index":2},
        {"op":"create-node","id":10,"kind":"column"},
        {"op":"create-extension","id":14,"identifier":"search-topbar-probe","fingerprint":"search-topbar-probe"},
        {"op":"insert-child","parent":10,"child":14,"index":0},
        {"op":"insert-child","parent":6,"child":10,"index":3},
        {"op":"create-node","id":11,"kind":"column"},
        {"op":"insert-child","parent":6,"child":11,"index":4},
        {"op":"create-node","id":12,"kind":"column"},
        {"op":"insert-child","parent":6,"child":12,"index":5},
        {"op":"insert-child","parent":2,"child":6,"index":0},
        {"op":"create-extension","id":5,"identifier":"search-home-probe","fingerprint":"search-home-probe"},
        {"op":"insert-child","parent":7,"child":5,"index":0},
        {"op":"create-node","id":3,"kind":"column"},
        {"op":"set-prop","id":3,"property":"grow","value":1.0},
        {"op":"create-extension","id":4,"identifier":"search-layout-probe","fingerprint":"search-layout-probe"},
        {"op":"insert-child","parent":3,"child":4,"index":0},
        {"op":"insert-child","parent":1,"child":2,"index":0},
        {"op":"insert-child","parent":1,"child":3,"index":1}]}
        """)
        func present(_ value: Bool) {
            generation += 1
            try! backend.apply(json: """
            {"generation":\(generation),"ops":[{"op":"set-extension-prop","id":1,"property":"presented","value":\(value)}]}
            """)
        }
        backend.onEvent = { event in
            if case .extension(_, _, "dismiss", _) = event { present(false) }
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LUISwiftUIRoot(backend: backend, rootID: 1))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        try await Task.sleep(for: .milliseconds(300))
        probe.homeBaseline = probe.homeFrame
        present(true)
        var field: UISearchTextField?
        for _ in 0..<150 {
            field = views(window).compactMap { $0 as? UISearchTextField }.first { $0.isFirstResponder }
            if field != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let field else { fatalError("Missing focused native search") }
        try await Task.sleep(for: .milliseconds(500))
        let fieldFrame = field.convert(field.bounds, to: window)
        guard let cancel = views(window).compactMap({ $0 as? UIControl }).first(where: { control in
            let frame = control.convert(control.bounds, to: window)
            guard frame.minX >= fieldFrame.maxX - 1, abs(frame.midY - fieldFrame.midY) < 24,
                  frame.width >= 20, frame.height >= 20, control.isEnabled, !control.isHidden else { return false }
            guard let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) else { return false }
            return hit === control || hit.isDescendant(of: control)
        }) else { fatalError("Missing native Cancel") }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let region = CGRect(x: 0, y: window.safeAreaInsets.top, width: window.bounds.width,
            height: fieldFrame.minY - window.safeAreaInsets.top - 4).integral
        func displayedFrame() -> (titleY: Double?, homeVisible: Bool, topbarVisible: Bool) {
            let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
            let cropped = image.cgImage!.cropping(to: region)!
            let width = cropped.width, height = cropped.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            var count = 0, totalY = 0, redCount = 0, leadingCount = 0, trailingCount = 0, topbarTitleCount = 0
            for y in 0..<height {
                for x in 0..<width {
                    let p = (y * width + x) * 4
                    if pixels[p] < 80 && pixels[p + 1] < 190 && pixels[p + 2] > 190 {
                        count += 1; totalY += y
                    }
                    if pixels[p] > 200 && pixels[p + 1] < 120 && pixels[p + 2] < 120 { redCount += 1 }
                    if y < 60 && x > width / 3 && x < width * 2 / 3 &&
                        pixels[p] < 100 && pixels[p + 1] < 100 && pixels[p + 2] < 100 {
                        topbarTitleCount += 1
                    }
                    if y < 60 && pixels[p + 1] > 140 && Int(pixels[p + 1]) > Int(pixels[p]) + 40 && Int(pixels[p + 1]) > Int(pixels[p + 2]) + 40 {
                        if x < width / 3 { leadingCount += 1 }
                        if x > width * 2 / 3 { trailingCount += 1 }
                    }
                }
            }
            return (count > 30 ? Double(totalY) / Double(count) : nil, redCount > width * height / 3, leadingCount > 100 && trailingCount > 100 && topbarTitleCount > 20)
        }
        guard !displayedFrame().topbarVisible else { fatalError("Search must hide the underlying topbar while active") }
        guard displayedFrame().titleY != nil else { fatalError("The visible search title must be measurable") }
        let keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                probe.keyboardAnimationDuration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
            }
        }
        defer { NotificationCenter.default.removeObserver(keyboardObserver) }
        let start = ProcessInfo.processInfo.systemUptime
        cancel.sendActions(for: cancel.allControlEvents.contains(.primaryActionTriggered) ? .primaryActionTriggered : .touchUpInside)
        var homeAfter: TimeInterval?
        var topbarAfter: TimeInterval?
        for _ in 0..<45 {
            let displayed = displayedFrame()
            guard displayed.homeVisible || displayed.titleY != nil else {
                throw NSError(domain: "SearchLayout", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Cancellation must preserve the outgoing content until the home page is visible, without an intermediate empty screen"])
            }
            if displayed.homeVisible && homeAfter == nil { homeAfter = ProcessInfo.processInfo.systemUptime - start }
            if displayed.topbarVisible && topbarAfter == nil { topbarAfter = ProcessInfo.processInfo.systemUptime - start }
            try await Task.sleep(for: .milliseconds(16))
        }
        let screenshot = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try screenshot.pngData()!.write(to: documents.appendingPathComponent("search-topbar-closed.png"))
        print("Cancellation rendered page at \(Int((homeAfter ?? -1) * 1000)) ms, complete topbar at \(Int((topbarAfter ?? -1) * 1000)) ms")
        guard let homeAfter else { fatalError("The underlying page must become visible after cancelling") }
        guard let topbarAfter, let nativeDuration = probe.keyboardAnimationDuration, topbarAfter < nativeDuration else {
            throw NSError(domain: "SearchLayout", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "The complete topbar must return during the native keyboard animation, without a second transition after dismissal; page=\(Int(homeAfter * 1000)) ms, topbar=\(Int((topbarAfter ?? -1) * 1000)) ms"])
        }
        guard homeAfter < 0.2 else {
            throw NSError(domain: "SearchLayout", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "The page must become visible as cancellation begins; page=\(Int(homeAfter * 1000)) ms"])
        }
        guard displayedFrame().titleY == nil else { fatalError("Closed search content must be hidden") }
        guard let capture = views(window).compactMap({ $0 as? UITextField }).first(where: {
            $0.placeholder == "Capture"
        }) else { fatalError("Missing home capture input") }
        try await Task.sleep(for: .milliseconds(300))
        capture.becomeFirstResponder()
        for _ in 0..<100 {
            if probe.homeFrame.height < probe.homeBaseline.height - 100 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard capture.isFirstResponder, probe.homeFrame.height < probe.homeBaseline.height - 100 else {
            throw NSError(domain: "SearchLayout", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "The home page must resume keyboard avoidance when its own input takes focus"])
        }
        capture.resignFirstResponder()
        print("PASS: native Cancel visibly restores home in \(Int(homeAfter * 1000)) ms and the complete topbar in \(Int(topbarAfter * 1000)) ms without an empty intermediate frame")
    }
}
