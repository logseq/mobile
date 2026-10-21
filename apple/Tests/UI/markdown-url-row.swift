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
      "statuses": [], "tags": [["uuid": "tag", "title": "Card"]],
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
    func matches(_ color: UIColor, _ expected: UIColor) -> Bool {
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
      color.resolvedColor(with: label.traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
      expected.getRed(&er, green: &eg, blue: &eb, alpha: &ea)
      return abs(r - er) < 0.001 && abs(g - eg) < 0.001 && abs(b - eb) < 0.001
    }
    let expectedLink = UIColor(red: 27.0 / 255, green: 104.0 / 255, blue: 152.0 / 255, alpha: 1)
    guard let color = label.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
      matches(color, expectedLink)
    else { throw failure("Native URL rows must use master's Logseq tag color instead of system blue") }
    guard let tag = views(row).compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == "button.block-tag.tag" }),
      matches(tag.tintColor, expectedLink)
    else { throw failure("Native tags and URL labels must share the same master color") }
    window.overrideUserInterfaceStyle = .dark
    try await Task.sleep(for: .milliseconds(350))
    let expectedDarkLink = UIColor(red: 155.0 / 255, green: 211.0 / 255, blue: 212.0 / 255, alpha: 1)
    guard let darkColor = label.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
      matches(darkColor, expectedDarkLink)
    else { throw failure("Unchanged URL rows must adopt master's dark tag color after switching appearance") }
    window.overrideUserInterfaceStyle = .light
    try await Task.sleep(for: .milliseconds(200))
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
