import SwiftUI
import UIKit
import Vision

@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class TagEffects: LGEffectExecuting {
  func execute(_ effect: LGEffect) async -> LGEffectResolution {
    LGEffectResolution(succeeded: true, message: "", output: .discard)
  }
}
@main struct TagAutocompletePositionCheck {
  @MainActor static func main() async throws {
    let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: TagEffects())
    try runtime.applyCoreResponse(
      ##"{"ok":true,"result":{"graphName":"Lambda","selectedGraphId":"lambda","outlinerRows":[{"depth":0,"block":{"uuid":"editing","title":"#Pr","pageId":"page"}}],"outlinerState":{"editing":{"uuid":"editing","title":"#Pr","caretUTF16Offset":3},"selectedBlockIds":[],"autocomplete":{"kind":"tag","query":"Pr"}},"outlinerAutocompleteCandidates":[{"label":"Project","value":"project"},{"label":"Progress","value":"progress"}]}}"##
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
    func views(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(views) }
    func projectPosition(_ name: String) throws -> CGFloat {
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(name + ".png"))
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
      guard
        let project = request.results?.first(where: {
          $0.topCandidates(1).first?.string == "Project"
        })
      else {
        throw NSError(
          domain: "TagPosition", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Tag list disappeared during typing"])
      }
      return project.boundingBox.midY
    }
    try await Task.sleep(for: .milliseconds(700))
    let initial = try projectPosition("tags-before-typing")
    let editor = views(window).compactMap { $0 as? UITextView }.first { $0.text == "#Pr" }!
    editor.insertText("o")
    try await Task.sleep(for: .milliseconds(250))
    let pending = try projectPosition("tags-during-typing")
    try runtime.applyCoreResponse(
      ##"{"ok":true,"result":{"isOutlinerPatch":true,"outlinerState":{"editing":{"uuid":"editing","title":"#Pro","caretUTF16Offset":4},"selectedBlockIds":[],"autocomplete":{"kind":"tag","query":"Pro"}},"outlinerAutocompleteCandidates":[{"label":"Project","value":"project"}]}}"##
    )
    try await Task.sleep(for: .milliseconds(350))
    let final = try projectPosition("tags-after-filtering")
    guard abs(initial - pending) < 0.005 && abs(initial - final) < 0.005 else {
      throw NSError(
        domain: "TagPosition", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Tag list moved: \(initial), \(pending), \(final)"])
    }
    print(
      "PASS: tag list remains visible at the same bottom position before typing, during the request, and after filtering"
    )
  }
}
