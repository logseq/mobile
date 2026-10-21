import SwiftUI
import UIKit
import Vision

@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class ReferenceEffects: LGEffectExecuting {
  func execute(_ effect: LGEffect) async -> LGEffectResolution {
    LGEffectResolution(succeeded: true, message: "", output: .discard)
  }
}
@main struct TagAutocompletePositionCheck {
  @MainActor static func main() async throws {
    for kind in ["tag", "node"] {
      let before = kind == "tag" ? "#Pr" : "[[Pr]]"
      let after = kind == "tag" ? "#Pro" : "[[Pro]]"
      let caret = kind == "tag" ? 3 : 4
      func snapshot(_ title: String, _ query: String, _ labels: [String], patch: Bool) throws -> String {
        let result: [String: Any] = ["graphName": "Lambda", "selectedGraphId": "lambda",
          "isOutlinerPatch": patch,
          "outlinerRows": [["depth": 0, "block": ["uuid": "editing", "title": title, "pageId": "page"]]],
          "outlinerState": ["editing": ["uuid": "editing", "title": title,
            "caretUTF16Offset": caret + (query == "Pro" ? 1 : 0)], "selectedBlockIds": [],
            "autocomplete": ["kind": kind, "query": query]],
          "outlinerAutocompleteCandidates": labels.map { ["label": $0, "value": $0.lowercased()] }]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
      }
      let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: ReferenceEffects())
      try runtime.applyCoreResponse(snapshot(before, "Pr", ["Project", "Progress"], patch: false))
      try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
      try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
      let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
      let window = UIWindow(windowScene: scene)
      window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
      window.makeKeyAndVisible()
      defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
      func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
      func positions(_ name: String) throws -> [String: CGFloat] {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
          window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(kind + "-" + name + ".png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
        return Dictionary((request.results ?? []).compactMap { observation in
          guard let label = observation.topCandidates(1).first?.string,
            ["Project", "Progress"].contains(label) else { return nil }
          return (label, observation.boundingBox.midY)
        }, uniquingKeysWith: { first, _ in first })
      }
      try await Task.sleep(for: .milliseconds(1200))
      let initial = try positions("before-typing")
      let editor = views(window).compactMap { $0 as? UITextView }.first { $0.text == before }!
      editor.insertText("o")
      try await Task.sleep(for: .milliseconds(350))
      let pending = try positions("during-typing")
      guard let start = initial["Project"], let waiting = pending["Project"], abs(start - waiting) < 0.005 else {
        throw failure("\(kind) candidates disappeared or moved during typing")
      }
      try runtime.applyCoreResponse(snapshot(after, "Pro", ["Progress"], patch: true))
      try await Task.sleep(for: .milliseconds(450))
      let filtered = try positions("after-filtering")
      guard let bottom = initial["Progress"], let final = filtered["Progress"], abs(bottom - final) < 0.005 else {
        throw failure("\(kind) results must stay against the bottom toolbar when their count shrinks")
      }
    }
    print("PASS: node and tag lists remain visible during typing and align their items with the bottom toolbar")
  }
  static func failure(_ message: String) -> NSError {
    NSError(domain: "ReferencePosition", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
