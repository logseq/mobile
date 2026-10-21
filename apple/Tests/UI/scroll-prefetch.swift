import SwiftUI
import UIKit
import Vision

@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class PrefetchEffects: LGEffectExecuting {
  var requests: [[String]] = []
  func execute(_ effect: LGEffect) async -> LGEffectResolution {
    guard effect.kind == "hydrate-outliner-rows", let data = effect.text.data(using: .utf8),
      let ids = try? JSONDecoder().decode([String].self, from: data)
    else { return LGEffectResolution(succeeded: true, message: "", output: .discard) }
    requests.append(ids)
    let blocks: [[String: Any]] = ids.map { id in
      [
        "uuid": id, "title": "Block \(id.replacingOccurrences(of:"prefetch-",with:""))",
        "pageId": "page",
      ]
    }
    let json: [String: Any] = [
      "ok": true,
      "result": [
        "selectedGraphId": "prefetch", "isOutlinerContentPatch": true, "hydratedBlocks": blocks,
      ],
    ]
    let encoded = String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    return LGEffectResolution(succeeded: true, message: encoded, output: .coreResponse)
  }
}
@main struct ScrollPrefetchCheck {
  @MainActor static func main() async throws {
    let effects = PrefetchEffects()
    let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
    let rows: [[String: Any]] = (0..<100).map { index in
      [
        "depth": index % 3,
        "block": [
          "uuid": "prefetch-\(index)", "title": index < 32 ? "Block \(index)" : "",
          "isShell": index >= 32, "pageId": "page",
        ],
      ]
    }
    let json: [String: Any] = [
      "ok": true,
      "result": [
        "graphName": "Prefetch check", "selectedGraphId": "prefetch", "outlinerRows": rows,
        "outlinerState": ["selectedBlockIds": []],
      ],
    ]
    try runtime.applyCoreResponse(
      String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self))
    try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
    try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(
      rootView: LGRendererRoot(renderer: runtime.renderer))
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      runtime.stop()
    }
    for _ in 0..<120 {
      if effects.requests.contains(where: { $0.contains("prefetch-40") }) { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    try await Task.sleep(for: .milliseconds(100))
    guard effects.requests.contains(where: { $0.contains("prefetch-40") }),
      effects.requests.allSatisfy({ $0.count <= 32 })
    else { throw failure("Adjacent content must load before scrolling, using bounded requests") }
    let backend = runtime.renderer.backend
    func ids(_ id: Int) -> [Int] {
      [id]
        + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? [])
        .flatMap(ids)
    }
    func find(_ name: String) -> Int? {
      backend.rootIDs.flatMap(ids).first {
        backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == name
      }
    }
    guard find("outliner.block.prefetch-40") == nil else {
      throw failure("Prefetch must not mount offscreen rows")
    }
    backend.performVisibleRange(node: find("outliner.window")!, first: 25, last: 45)
    try await Task.sleep(for: .milliseconds(100))
    guard let row = find("outliner.block.prefetch-40") else {
      throw failure("The next window did not mount")
    }
    let model = ids(row).compactMap { backend.extensionModel(id: $0) }
      .first { $0.identifier == "outliner-block-row" }!
    guard case .string(let payload) = model.property("payload"), payload.contains("Block 40") else {
      throw failure(
        "The destination row must mount with prefetched content instead of a loading skeleton")
    }
    func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    let scroll = views(window).compactMap { $0 as? UIScrollView }.filter { $0.bounds.height > 300 }
      .max { $0.contentSize.height < $1.contentSize.height }!
    scroll.setContentOffset(CGPoint(x: 0, y: 840), animated: false)
    try await Task.sleep(for: .milliseconds(350))
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    try image.pngData()!.write(
      to: URL.documentsDirectory.appendingPathComponent("scroll-prefetched-content.png"))
    print(
      "PASS: native scrolling mounts prefetched content; all hydration requests contain at most 32 rows"
    )
  }
  static func failure(_ message: String) -> NSError {
    NSError(domain: "ScrollPrefetch", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
