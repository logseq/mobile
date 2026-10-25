import SwiftUI
import UIKit
@testable import LUIAppleBackend

@main struct LocalizedDialogCancelCheck {
    @MainActor static func main() async throws {
        for (cancel, delete) in [("Cancel", "Delete"), ("取消", "删除"), ("キャンセル", "削除"), ("Annuler", "Supprimer")] {
            let backend = LUIAppleBackend()
            let operations: [[String: Any]] = [
                ["op": "create-node", "id": 1, "kind": "column"],
                ["op": "create-node", "id": 2, "kind": "dialog"],
                ["op": "create-node", "id": 3, "kind": "button"],
                ["op": "create-node", "id": 4, "kind": "button"],
                ["op": "set-prop", "id": 2, "property": "text", "value": delete],
                ["op": "set-prop", "id": 2, "property": "style-class", "value": "alert"],
                ["op": "set-prop", "id": 3, "property": "text", "value": cancel],
                ["op": "set-prop", "id": 3, "property": "style-class", "value": "quiet cancellation-action"],
                ["op": "set-prop", "id": 4, "property": "text", "value": delete],
                ["op": "set-prop", "id": 4, "property": "variant", "value": "destructive"],
                ["op": "insert-child", "parent": 1, "child": 2, "index": 0],
                ["op": "insert-child", "parent": 2, "child": 3, "index": 0],
                ["op": "insert-child", "parent": 2, "child": 4, "index": 1]
            ]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: ["generation": 1, "ops": operations]), as: UTF8.self)
            try backend.apply(json: json)
            let dialog = backend.model(id: 2)!
            guard LUIDialogContentPolicy.cancelActionID(dialog: dialog, backend: backend) == 3,
                  LUIDialogContentPolicy.nonCancelActionIDs(dialog: dialog, backend: backend) == [4] else {
                throw NSError(domain: "LocalizedDialogCancel", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "A localized dialog must have exactly one semantic cancellation action: \(cancel)"])
            }
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: LUISwiftUIRoot(backend: backend, rootID: 1))
            window.rootViewController = host
            window.makeKeyAndVisible()
            var alert: UIAlertController?
            for _ in 0..<100 {
                if let presented = host.presentedViewController as? UIAlertController {
                    alert = presented
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let alert, alert.actions.count == 2,
                  alert.actions.filter({ $0.style == .cancel }).map(\.title) == [cancel],
                  alert.actions.filter({ $0.style == .destructive }).map(\.title) == [delete] else {
                throw NSError(domain: "LocalizedDialogCancel", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Native alerts must not append another Cancel button: \(cancel)"])
            }
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        print("PASS: English, Chinese, Japanese and French alerts each render one Cancel and one Delete")
    }
}
