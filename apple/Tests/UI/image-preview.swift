import Foundation
import UIKit
import ImageIO
@testable import Logseq

@main struct CheckImagePreview {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8S8AAAAASUVORK5CYII=")!
        let urls = [directory.appendingPathComponent("first.png"), directory.appendingPathComponent("second.png")]
        for url in urls { try bytes.write(to: url) }
        let gallery = LGImagePreview.Gallery(urls: urls, selectedIndex: 1)
        let screen = LGImagePreview.Screen(preview: gallery)
        screen.loadViewIfNeeded()
        precondition(screen.currentURL == urls[1], "Tapping an image must start at that image")
        precondition(screen.navigationItem.rightBarButtonItems?.count == 2, "Preview provides Save to Photos and Share")
        let first = gallery.pageViewController(gallery, viewControllerBefore: gallery.currentPage!)!
        let next = gallery.pageViewController(gallery, viewControllerAfter: first) as! LGImagePreview.ImagePage
        precondition(next.url == urls[1], "Native paging preserves the image order")
        next.loadViewIfNeeded()
        let zoom = next.view.subviews.compactMap { $0 as? UIScrollView }.first!
        precondition(zoom.minimumZoomScale == 1 && zoom.maximumZoomScale == 8)
        zoom.zoomScale = 2
        next.scrollViewDidZoom(zoom)
        precondition(zoom.panGestureRecognizer.isEnabled, "Zoomed images own pan gestures")
        zoom.zoomScale = 1
        next.scrollViewDidZoom(zoom)
        precondition(!zoom.panGestureRecognizer.isEnabled, "At fit size horizontal gestures change images")
        let lease = try LGPhotoSaveFile.stage(urls[0])
        let stagedBytes = try Data(contentsOf: lease.url)
        precondition(stagedBytes == bytes, "Saving must preserve original image bytes")
        let staged = lease.url
        lease.close()
        precondition(!FileManager.default.fileExists(atPath: staged.path))
        print("PASS: full-screen image paging, zoom, save/share controls, and lossless save staging")
    }
}
