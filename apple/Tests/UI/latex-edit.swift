import SwiftUI
import UIKit
import WebKit
@testable import Logseq
@testable import LUIAppleBackend

@main
struct LatexEditCheck {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func main() async throws {
        let backend = try LUIAppleBackend(extensionRegistry: LGExtensionRegistry.makeRegistry())
        var events: [LUIEvent] = []
        backend.onEvent = { events.append($0) }
        var generation = 0
        func apply(_ ops: [[String: Any]]) throws {
            generation += 1
            try backend.apply(json: String(decoding: JSONSerialization.data(withJSONObject:
                ["generation": generation, "ops": ops]), as: UTF8.self))
        }
        var creation: [[String: Any]] = [
            ["op": "create-node", "id": 1, "kind": "panel"],
            ["op": "create-extension", "id": 2, "identifier": OutlinerRowExtension.identifier,
             "fingerprint": OutlinerRowExtension.fingerprint],
            ["op": "insert-child", "parent": 1, "child": 2, "index": 0],
        ]
        func setMarkup(_ markup: [[String: Any]]) throws {
            let payload: [String: Any] = [
                "uuid": "math", "title": "x^2", "markup": markup, "depth": 0,
                "hasChildren": false, "collapsed": false, "isAsset": false,
                "assetType": "", "localPath": "", "youtubeURL": "", "completed": false,
                "selected": false, "editing": false, "hasCustomContent": false,
                "opensAsPage": false, "journalBullet": false, "syncFailed": false,
                "statuses": [], "tags": [],
            ]
            try apply(creation + [["op": "set-extension-prop", "id": 2, "property": "payload",
                        "value": String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self)]])
            creation.removeAll()
        }
        try setMarkup([["type": "math", "style": "display", "text": "x^2"]])
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LUISwiftUIRoot(backend: backend, rootID: 1))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func renderedWebView() async throws -> WKWebView {
            for _ in 0..<80 {
                if let web = views(window).compactMap({ $0 as? WKWebView }).first,
                   (try? await web.evaluateJavaScript("document.querySelectorAll('.katex').length")) as? Int == 1 {
                    return web
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw Failure(description: "LaTeX formula did not render")
        }
        func editCount() -> Int {
            events.filter {
                if case .extension(node: 2, identifier: _, name: "edit", values: let values) = $0 {
                    return values["uuid"] == .string("math")
                }
                return false
            }.count
        }
        var failures: [String] = []
        let cases: [(String, [[String: Any]])] = [
            ("display", [["type": "math", "style": "display", "text": "x^2"]]),
            ("inline", [["type": "text", "text": "Formula "],
                        ["type": "math", "style": "inline", "text": "x^2"]]),
            ("linked", [["type": "math", "style": "inline", "text": "x^2"],
                        ["type": "nodeReference", "uuid": "target", "title": "Formula"]]),
        ]
        for (name, markup) in cases {
            try setMarkup(markup)
            try await Task.sleep(for: .milliseconds(250))
            let web = try await renderedWebView()
            let before = editCount()
            _ = try await web.evaluateJavaScript("document.querySelector('[data-tex] .katex-html').click()")
            try await Task.sleep(for: .milliseconds(100))
            if editCount() != before + 1 { failures.append("Tapping \(name) LaTeX did not emit exactly one edit event") }
            let beforeLock = editCount()
            backend.setDrawerInteractionLocked(true, node: 1)
            _ = try await web.evaluateJavaScript("document.querySelector('[data-tex]').click()")
            try await Task.sleep(for: .milliseconds(100))
            if editCount() != beforeLock { failures.append("Locked \(name) LaTeX emitted an edit event") }
            backend.setDrawerInteractionLocked(false, node: 1)
            if name == "linked" {
                let linkBefore = editCount()
                _ = try await web.evaluateJavaScript("document.querySelector('a').click()")
                try await Task.sleep(for: .milliseconds(200))
                if editCount() != linkBefore { failures.append("A node link entered edit mode") }
                if !events.contains(where: {
                    if case .extension(node: 2, identifier: _, name: "open-node", values: let values) = $0 {
                        return values["uuid"] == .string("target")
                    }
                    return false
                }) { failures.append("A node link stopped opening its target") }
            }
        }
        if !failures.isEmpty { throw Failure(description: failures.joined(separator: "\n")) }
        print("PASS: display and inline LaTeX taps edit once; node links and drawer locks remain respected")
    }
}
