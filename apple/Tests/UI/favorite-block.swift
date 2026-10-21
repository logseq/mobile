import SwiftUI
import UIKit
import Vision

@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class FavoriteEffects: LGEffectExecuting {
  var opened: String?
  func execute(_ effect: LGEffect) async -> LGEffectResolution {
    if effect.kind == "open-node" { opened = effect.text }
    return LGEffectResolution(succeeded: true, message: "", output: .discard)
  }
}
@main struct FavoriteBlockCheck {
  @MainActor static func main() async throws {
    let effects = FavoriteEffects()
    let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
    try runtime.applyCoreResponse(
      #"{"ok":true,"result":{"graphName":"Lambda","selectedGraphId":"lambda","favorites":[{"uuid":"saved-block","title":"Saved block"},{"uuid":"page","title":"Project page"}],"outlinerRows":[],"outlinerState":{"selectedBlockIds":[]}}}"#
    )
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
    try await Task.sleep(for: .milliseconds(600))
    let backend = runtime.renderer.backend
    func ids(_ id: Int) -> [Int] {
      [id]
        + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? [])
        .flatMap(ids)
    }
    let drawer = backend.rootIDs.flatMap(ids).first { backend.model(id: $0)?.kind == .drawer }!
    try backend.performToggle(node: drawer, checked: true)
    try await Task.sleep(for: .milliseconds(450))
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    try image.pngData()!.write(
      to: URL.documentsDirectory.appendingPathComponent("favorite-block.png"))
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
    let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
      separator: " ")
    guard visible.contains("Saved block") && visible.contains("Project page") else {
      throw NSError(
        domain: "FavoriteBlock", code: 1, userInfo: [NSLocalizedDescriptionKey: visible])
    }
    try await Task.sleep(for: .milliseconds(500))
    let link = backend.rootIDs.flatMap(ids).first {
      backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue
        == "link.sidebar.page.saved-block"
    }!
    try backend.performPress(node: link)
    try await Task.sleep(for: .milliseconds(350))
    await runtime.drainEffectsForTesting()
    guard effects.opened == "saved-block" else {
      throw NSError(
        domain: "FavoriteBlock", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Favorite must open its block UUID"])
    }
    print("PASS: Favorites shows both blocks and pages and opens a favorite block by UUID")
  }
}
