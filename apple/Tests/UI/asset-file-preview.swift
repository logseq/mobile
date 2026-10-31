import SwiftUI
import UIKit
import QuickLook
@testable import Logseq

@main
struct AssetFilePreviewCheck {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pages = directory.appendingPathComponent("Blank.pages")
        // The regression concerns opening the attachment, independently of its document contents.
        try Data("Pages attachment".utf8).write(to: pages)
        let pdf = directory.appendingPathComponent("Document.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
            .writePDF(to: pdf) { context in
                context.beginPage()
                NSString(string: "Attachment preview").draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
            }
        let missing = directory.appendingPathComponent("Retry.pages")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var failures: [String] = []

        func preview(in controller: UIViewController) -> QLPreviewController? {
            if let preview = controller as? QLPreviewController { return preview }
            if let presented = controller.presentedViewController, let found = preview(in: presented) { return found }
            return controller.children.compactMap { preview(in: $0) }.first
        }
        for url in [pages, pdf, missing] {
            let controller = UIHostingController(rootView: LGAssetPreview(
                uuid: "file-preview-check", title: url.lastPathComponent,
                assetType: url.pathExtension, localPath: url.path))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutIfNeeded()
            // check-asset-file-preview.sh taps the actual SwiftUI button with Maestro.
            for _ in 0..<600 {
                if controller.presentedViewController != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            if url == missing {
                guard let alert = controller.presentedViewController as? UIAlertController else {
                    failures.append("An unavailable attachment failed without visible feedback")
                    continue
                }
                if alert.message?.isEmpty != false { failures.append("Download failure feedback has no explanation") }
            } else if let preview = preview(in: controller), let source = preview.dataSource,
                      let item = source.previewController(preview, previewItemAt: 0).previewItemURL {
                if item.standardizedFileURL != url.standardizedFileURL {
                    failures.append("Preview opened the wrong file for \(url.lastPathComponent)")
                }
            } else {
                failures.append("\(url.lastPathComponent) did not open the native document preview")
            }
            controller.dismiss(animated: false)
            try await Task.sleep(for: .milliseconds(100))
        }
        if !failures.isEmpty { throw Failure(description: failures.joined(separator: "\n")) }
        print("PASS: Pages and PDF attachments open Quick Look; unavailable files show download errors")
    }
}
