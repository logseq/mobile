import SwiftUI
import UIKit

@testable import LUIAppleBackend
@testable import Logseq

@MainActor final class ScrollFrames: NSObject {
  var link: CADisplayLink?
  var gaps: [Double] = []
  var last = 0.0
  func start() {
    gaps = []
    last = ProcessInfo.processInfo.systemUptime
    let l = CADisplayLink(target: self, selector: #selector(tick))
    l.preferredFramesPerSecond = 60
    l.add(to: .main, forMode: .common)
    link = l
  }
  @objc func tick() {
    let t = ProcessInfo.processInfo.systemUptime
    gaps.append((t - last) * 1000)
    last = t
  }
  func finish(_ name: String) -> (Double, Double) {
    link?.invalidate()
    link = nil
    let a = gaps.sorted()
    let p = a[min(a.count - 1, Int(Double(a.count) * 0.95))]
    let m = a.last!
    print("SCROLL_FRAMES kind=\(name) count=\(a.count) p95_ms=\(p) max_ms=\(m)")
    return (p, m)
  }
}
@MainActor private final class NoEffects: LGEffectExecuting {
  func execute(_ effect: LGEffect) async -> LGEffectResolution {
    LGEffectResolution(succeeded: true, message: "", output: .discard)
  }
}
@main struct MarkdownScrollCheck {
  @MainActor static func main() async throws {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
    var stats: [String: (Double, Double)] = [:]
    for kind in ["plain", "links"] {
      let rows: [[String: Any]] = (0..<600).map { i in
        let markup: [[String: Any]] = (0..<8).flatMap { j in
          [
            [
              "type": kind == "links" ? "link" : "text", "text": "Reference \(i)-\(j)",
              "url": "https://example.com/notes/\(i)/\(j)",
              "children": [["type": "text", "text": "Reference \(i)-\(j)"]],
            ], ["type": "text", "text": " "],
          ]
        }
        return [
          "depth": i % 3,
          "block": [
            "uuid": "row-\(i)", "title": "References \(i)", "pageId": "page", "markup": markup,
          ],
        ]
      }
      let json: [String: Any] = [
        "ok": true,
        "result": [
          "graphName": "Scroll benchmark", "selectedGraphId": "benchmark", "outlinerRows": rows,
          "outlinerState": ["selectedBlockIds": []],
        ],
      ]
      let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: NoEffects())
      try runtime.applyCoreResponse(
        String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self))
      try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
      try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
      let window = UIWindow(windowScene: scene)
      window.rootViewController = UIHostingController(
        rootView: LGRendererRoot(renderer: runtime.renderer))
      window.makeKeyAndVisible()
      try await Task.sleep(for: .milliseconds(1100))
      func views(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(views) }
      guard
        let scroll = views(window).compactMap({ $0 as? UIScrollView }).filter({
          $0.bounds.height > 300
        }).max(by: { $0.contentSize.height < $1.contentSize.height })
      else { fatalError("No outline scroll view") }
      if ProcessInfo.processInfo.environment["LOGSEQ_PROFILE_PAUSE"] == "1" && kind == "plain" {
        try await Task.sleep(for: .seconds(20))
      }
      print("SCROLL_PHASE kind=\(kind) uptime=\(ProcessInfo.processInfo.systemUptime)")
      let frames = ScrollFrames()
      frames.start()
      for step in 0..<150 {
        scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(step) * 22), animated: false)
        try await Task.sleep(for: .milliseconds(16))
      }
      stats[kind] = frames.finish(kind)
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      try image.pngData()!.write(
        to: URL.documentsDirectory.appendingPathComponent("scroll-\(kind).png"))
      window.isHidden = true
      window.rootViewController = nil
      runtime.stop()
    }
    guard let links = stats["links"], links.0 < 34, links.1 < 100 else {
      throw NSError(
        domain: "MarkdownScroll", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Markdown links exceeded scrolling frame budget: \(stats)"
        ])
    }
    print("PASS: Markdown URL scrolling stays within its frame budget")
  }
}
