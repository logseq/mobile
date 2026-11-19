import SwiftUI
import UIKit
@testable import Logseq
@testable import LUIAppleBackend

@main struct NavigationRouteAdmissionCheck {
    @MainActor static func main() async throws {
        let registry = LUIAppleExtensionRegistry()
        try LGNavigationExtension.register(in: registry)
        let backend = try LUIAppleBackend(extensionRegistry: registry)
        var generation = 0
        func apply(_ ops: [[String: Any]]) throws {
            generation += 1
            let patch: [String: Any] = ["generation": generation, "ops": ops]
            try backend.apply(json: String(decoding: JSONSerialization.data(withJSONObject: patch), as: UTF8.self))
        }
        func property(_ name: String, _ value: Any) -> [String: Any] {
            ["op": "set-extension-prop", "id": 1, "property": name, "value": value]
        }
        func insert(_ id: Int, at index: Int, parent: Int = 1) -> [String: Any] {
            ["op": "insert-child", "parent": parent, "child": id, "index": index]
        }
        let slots = (2...8).flatMap { id -> [[String: Any]] in
            [["op": "create-node", "id": id, "kind": "column"], insert(id, at: id - 2)]
        }
        // The seventh child is the capture controls while there's no page route.
        try apply([
            ["op": "create-extension", "id": 1, "identifier": LGNavigationExtension.identifier,
             "fingerprint": LGNavigationExtension.fingerprint],
            property("depth", 0), property("back-depth", 0), property("title", "Journal"),
            property("bottom-occupies-layout-space", false), property("composer-dismissal-enabled", false),
        ] + slots + [
            ["op": "set-prop", "id": 8, "property": "accessibility-identifier", "value": "navigation.capture-controls"],
        ])

        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw failure("Missing simulator scene")
        }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: LUISwiftUIRoot(backend: backend, rootID: 1))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        func navigation(in controller: UIViewController) -> UINavigationController? {
            (controller as? UINavigationController) ?? controller.children.lazy.compactMap(navigation).first
        }
        for _ in 0..<100 where navigation(in: host) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let navigation = navigation(in: host), let journal = navigation.topViewController else {
            throw failure("The journal must start in a native navigation stack")
        }

        try apply([property("depth", 1)])
        try await Task.sleep(for: .milliseconds(300))
        guard navigation.topViewController === journal, navigation.viewControllers.count == 1 else {
            throw failure("A pending page must never push the capture controls")
        }

        try apply([
            ["op": "create-extension", "id": 9, "identifier": LGNavigationExtension.destinationIdentifier,
             "fingerprint": LGNavigationExtension.destinationFingerprint],
            ["op": "set-extension-prop", "id": 9, "property": "title", "value": "Linked page"],
            ["op": "create-node", "id": 10, "kind": "column"],
            insert(10, at: 0, parent: 9), insert(9, at: 6),
        ])
        for _ in 0..<100 {
            if navigation.viewControllers.count == 2, navigation.topViewController?.navigationItem.title == "Linked page" {
                print("PASS: only the linked page enters the navigation stack")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw failure("The linked page must push once its view arrives")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "NavigationRouteAdmission", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
