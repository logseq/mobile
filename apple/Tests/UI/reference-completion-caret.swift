import SwiftUI
import UIKit

@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class CompletionEffects: LGEffectExecuting {
  let response: String
  var choices = 0
  init(response: String) { self.response = response }
  func execute(_ effect: LGEffect) async -> LGEffectResolution {
    if effect.kind == "choose-outliner-autocomplete" {
      choices += 1
      return LGEffectResolution(succeeded: true, message: response, output: .coreResponse)
    }
    return LGEffectResolution(succeeded: true, message: "", output: .discard)
  }
}
@main struct ReferenceCompletionCaretCheck {
  @MainActor static func main() async throws {
    for (prefix, label, suffix) in [("", "wow", ""), ("😀 ", "页面", " tail")] {
      let title = prefix + "[[" + label + "]]" + suffix
      let inside = (prefix + "[[" + label).utf16.count
      let outside = inside + 2
      func snapshot(caret: Int, completed: Bool) throws -> String {
        var state: [String: Any] = ["editing": ["uuid": "editing", "title": title, "caretUTF16Offset": caret],
          "selectedBlockIds": []]
        if !completed { state["autocomplete"] = ["kind": "node", "query": label] }
        let result: [String: Any] = ["graphName": "Lambda", "selectedGraphId": "lambda",
          "outlinerRows": [["depth": 0, "block": ["uuid": "editing", "title": title, "pageId": "page"]]],
          "outlinerState": state, "outlinerAutocompleteCandidates": completed ? [] : [["label": label, "value": "page"]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
      }
      let completed = try snapshot(caret: outside, completed: true)
      let effects = CompletionEffects(response: completed)
      let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
      try runtime.applyCoreResponse(snapshot(caret: inside, completed: false))
      try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
      try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
      let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
      let window = UIWindow(windowScene: scene)
      window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
      window.makeKeyAndVisible()
      defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
      func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
      try await Task.sleep(for: .milliseconds(1200))
      await runtime.drainEffectsForTesting()
      try runtime.applyCoreResponse(snapshot(caret: inside, completed: false))
      try await Task.sleep(for: .milliseconds(400))
      let editor = views(window).compactMap { $0 as? UITextView }.first { $0.text == title }!
      guard editor.selectedRange.location == inside else { throw failure("Initial reference caret is incorrect") }
      let backend = runtime.renderer.backend
      func ids(_ id: Int) -> [Int] {
        [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(ids)
      }
      let candidate = backend.rootIDs.flatMap(ids).first {
        backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == "button.outliner.autocomplete.0"
      }!
      try backend.performPress(node: candidate)
      try await Task.sleep(for: .milliseconds(500))
      await runtime.drainEffectsForTesting()
      try await Task.sleep(for: .milliseconds(350))
      guard effects.choices == 1 else { throw failure("The reference candidate did not dispatch its selection") }
      guard editor.text == title, editor.selectedRange == NSRange(location: outside, length: 0) else {
        throw failure("Confirming an unchanged reference must move the caret after ]]: \(editor.selectedRange), expected \(outside)")
      }
      editor.selectedRange = NSRange(location: 0, length: 2)
      try runtime.applyCoreResponse(completed)
      try await Task.sleep(for: .milliseconds(300))
      guard editor.selectedRange == NSRange(location: 0, length: 2) else {
        throw failure("Ordinary acknowledgements must preserve a newer native word selection")
      }
      editor.selectedRange = NSRange(location: outside, length: 0)
      editor.insertText("x")
      guard editor.text == prefix + "[[" + label + "]]x" + suffix else {
        throw failure("Typing after confirmation must insert outside the reference")
      }
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(prefix.isEmpty ? "reference-caret.png" : "unicode-reference-caret.png"))
    }
    print("PASS: reference confirmation moves the caret after ]], including unchanged text, Unicode and suffixes; acknowledgements preserve native selection")
  }
  static func failure(_ message: String) -> NSError {
    NSError(domain: "ReferenceCaret", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
