import SwiftUI
import UIKit

@testable import LUIAppleBackend
@testable import Logseq

@main struct MarkdownURLRowCheck {
  @MainActor static func main() async throws {
    var payload: [String: Any] = [
      "uuid": "url-row", "title": "文档 😀 after",
      "markup": [
        [
          "type": "link", "url": "https://example.com/docs?language=zh",
          "children": [["type": "text", "text": "文档 😀"]],
        ], ["type": "text", "text": " after"],
      ],
      "depth": 2, "hasChildren": false, "collapsed": false, "isAsset": false,
      "assetType": "", "localPath": "", "youtubeURL": "", "completed": false,
      "selected": false, "opensAsPage": false, "journalBullet": false, "syncFailed": false,
      "statuses": [], "tags": [],
    ]
    let backend = try LUIAppleBackend(
      appIcons: LGIconPolicy.icons, extensionRegistry: LGExtensionRegistry.makeRegistry())
    func encoded() throws -> String {
      String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }
    func apply(_ ops: [[String: Any]], generation: Int) throws {
      try backend.apply(
        json: String(
          decoding: JSONSerialization.data(withJSONObject: ["generation": generation, "ops": ops]),
          as: UTF8.self))
    }
    try apply(
      [
        [
          "op": "create-extension", "id": 1, "identifier": OutlinerRowExtension.identifier,
          "fingerprint": OutlinerRowExtension.fingerprint,
        ], ["op": "set-extension-prop", "id": 1, "property": "payload", "value": encoded()],
      ], generation: 1)
    var opened: [URL] = []
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(
      rootView: LUISwiftUIRoot(backend: backend, rootID: 1).environment(
        \.openURL,
        OpenURLAction {
          opened.append($0)
          return .handled
        }))
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }
    try await Task.sleep(for: .milliseconds(500))
    func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    guard let row = views(window).compactMap({ $0 as? OutlinerTextRowView }).first,
      let label = views(row).compactMap({ $0 as? UILabel }).first(where: {
        $0.accessibilityIdentifier == "outliner.block-action.url-row"
      })
    else { throw failure("URL rows must render readable native inline text") }
    guard label.attributedText?.string == "文档 😀 after" else {
      throw failure("Unicode link labels and surrounding text must survive rendering")
    }
    row.activateTitle(at: CGPoint(x: 8, y: label.font.lineHeight / 2))
    guard opened.last?.absoluteString == "https://example.com/docs?language=zh" else {
      throw failure("Tapping a Unicode URL label must open its destination")
    }
    let action = label.accessibilityCustomActions!.first!
    guard action.actionHandler?(action) == true, opened.count == 2 else {
      throw failure("VoiceOver must offer the inline link action")
    }
    var events: [LUIEvent] = []
    backend.onEvent = { events.append($0) }
    row.activateTitle(at: CGPoint(x: label.bounds.width - 1, y: label.font.lineHeight / 2))
    guard
      events.contains(where: {
        if case .extension(_, _, "edit", _) = $0 { return true }
        return false
      })
    else { throw failure("Tapping outside a link must still edit the block") }
    payload["markup"] = [
      [
        "type": "link", "url": "https://example.com/updated",
        "children": [["type": "text", "text": "Updated URL"]],
      ]
    ]
    payload["completed"] = true
    try apply(
      [["op": "set-extension-prop", "id": 1, "property": "payload", "value": encoded()]],
      generation: 2)
    try await Task.sleep(for: .milliseconds(200))
    guard label.attributedText?.string == "Updated URL" else {
      throw failure("Reusing a URL row must not retain its old decoded payload")
    }
    let updatedAction = label.accessibilityCustomActions!.first!
    _ = updatedAction.actionHandler?(updatedAction)
    guard opened.last?.absoluteString == "https://example.com/updated" else {
      throw failure("Reusing a row must replace its link action")
    }
    guard label.attributedText?.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil
    else { throw failure("Completed URL rows retain their text styling") }
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    try image.pngData()!.write(
      to: URL.documentsDirectory.appendingPathComponent("markdown-url-row.png"))
    print(
      "PASS: URL labels preserve Unicode, touch and VoiceOver activation, editing, completed styling, and row reuse"
    )
  }
  static func failure(_ message: String) -> NSError {
    NSError(domain: "MarkdownURLRow", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
