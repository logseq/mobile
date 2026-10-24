import SwiftUI
import UIKit
import MachO
@testable import LUIAppleBackend

@main struct FilePreviewLaunchCheck {
    @MainActor static func main() async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "FilePreviewLaunch", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func quickLookLoaded() -> Bool {
            (0..<_dyld_image_count()).contains { index in
                guard let image = _dyld_get_image_name(index) else { return false }
                return String(cString: image).contains("/QuickLook.framework/")
            }
        }
        try require(!quickLookLoaded(), "File preview must not load QuickLook before it is requested")
        let backend = LUIAppleBackend()
        try backend.apply(json: #"{"generation":1,"ops":[{"op":"create-node","id":1,"kind":"column"}]}"#)
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }!
        let window = UIWindow(windowScene: previousWindow.windowScene!)
        window.frame = previousWindow.bounds
        let host = UIHostingController(rootView: LUISwiftUIRoot(backend: backend, rootID: 1))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(100))
        try require(!quickLookLoaded(), "An idle file-preview host must not load QuickLook")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lui-preview.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 480))
        try renderer.writePDF(to: file) { context in
            context.beginPage()
            ("Native file preview" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        var events: [LUIEvent] = []
        backend.onEvent = { events.append($0) }
        let path = String(data: try JSONEncoder().encode(file.path), encoding: .utf8)!
        try backend.apply(json: """
        {"generation":2,"ops":[
          {"op":"create-node","id":2,"kind":"file-preview"},
          {"op":"set-prop","id":2,"property":"path","value":\(path)},
          {"op":"insert-child","parent":1,"child":2,"index":0}
        ]}
        """)
        for _ in 0..<100 where host.presentedViewController == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(host.presentedViewController != nil, "Requesting a file must present the native preview")
        try require(quickLookLoaded(), "The native preview must load QuickLook on demand")
        try await Task.sleep(for: .milliseconds(10))
        try backend.apply(json: #"{"generation":3,"ops":[{"op":"remove-child","parent":1,"child":2},{"op":"drop-node","id":2}]}"#)
        for _ in 0..<100 where host.presentedViewController != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(host.presentedViewController == nil, "Removing the preview must dismiss its native controller")
        try require(events.isEmpty, "A wire-driven dismissal must not emit a duplicate dismiss event")
        try backend.apply(json: """
        {"generation":4,"ops":[
          {"op":"create-node","id":3,"kind":"file-preview"},
          {"op":"set-prop","id":3,"property":"path","value":\(path)},
          {"op":"insert-child","parent":1,"child":3,"index":0}
        ]}
        """)
        for _ in 0..<100 where host.presentedViewController == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(host.presentedViewController != nil, "A closed native preview must be able to reopen")
        try await Task.sleep(for: .milliseconds(500))
        host.presentedViewController?.dismiss(animated: false)
        for _ in 0..<100 where events.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(events == [.dismiss(node: 3)], "Closing the native preview must emit exactly one dismiss event")
        try backend.apply(json: #"{"generation":5,"ops":[{"op":"set-prop","id":3,"property":"path","value":"/tmp/retained-preview.pdf"}]}"#)
        try await Task.sleep(for: .milliseconds(100))
        try require(host.presentedViewController == nil, "A dismissed wire node must not immediately reopen")
        print("PASS: file preview loads QuickLook on demand, presents PDF, dismisses, and reopens safely")
    }
}
