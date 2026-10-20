import AppKit
import LUIAppleBackend
import OSLog
import SwiftUI

let logger = Logger(subsystem: "com.logseq.navigation-regression", category: "test")

// Exercise the real retained renderer and SwiftUI toolbar closures in Release.
@MainActor
func runNavigationLifecycle() throws {
    precondition(LGIconPolicy.icons["more-horiz"] == .systemName("ellipsis"),
                 "Page and block menus must use the same native ellipsis as master")
    let registry = LUIAppleExtensionRegistry()
    try LGNavigationExtension.register(in: registry)
    let backend = try LUIAppleBackend(extensionRegistry: registry)
    backend.coalescesCommits = true
    var generation = 0
    func apply(_ operations: [[String: Any]]) throws {
        generation += 1
        let data = try JSONSerialization.data(withJSONObject: ["generation": generation, "ops": operations])
        try backend.apply(json: String(decoding: data, as: UTF8.self))
    }
    func pump() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
    }
    try apply([
        ["op": "create-node", "id": 1, "kind": "root"],
        ["op": "create-extension", "id": 2, "identifier": "native-navigation-stack",
         "fingerprint": LGNavigationExtension.fingerprint],
        ["op": "set-extension-prop", "id": 2, "property": "back-depth", "value": 0],
        ["op": "set-extension-prop", "id": 2, "property": "depth", "value": 0],
        ["op": "set-extension-prop", "id": 2, "property": "bottom-occupies-layout-space", "value": false],
        ["op": "set-extension-prop", "id": 2, "property": "composer-dismissal-enabled", "value": false],
        ["op": "set-extension-prop", "id": 2, "property": "title", "value": "Lifecycle regression"],
        ["op": "insert-child", "parent": 1, "child": 2, "index": 0],
    ])
    let controller = NSHostingController(rootView: LUISwiftUIRoot(backend: backend, rootID: 1))
    let window = NSWindow(contentViewController: controller)
    window.setContentSize(NSSize(width: 390, height: 844))
    window.makeKeyAndOrderFront(nil)
    pump()
    // Children arrive incrementally; each toolbar slot may be absent.
    for index in 0..<6 {
        let id = index + 3
        try apply([
            ["op": "create-node", "id": id, "kind": "text"],
            ["op": "set-prop", "id": id, "property": "text", "value": "Slot \(index)"],
            ["op": "insert-child", "parent": 2, "child": id, "index": index],
        ])
        pump()
    }
    // SwiftUI can evaluate an outgoing toolbar after its retained node is gone.
    try apply([
        ["op": "create-node", "id": 9, "kind": "text"],
        ["op": "set-prop", "id": 9, "property": "text", "value": "Replacement root"],
        ["op": "remove-child", "parent": 1, "child": 2],
        ["op": "detach-subtree", "id": 2],
        ["op": "insert-child", "parent": 1, "child": 9, "index": 0],
    ])
    pump()
    precondition(backend.rootIDs == [1])
    window.orderOut(nil)
    print("PASS: empty, partial, populated and removed navigation render safely")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
try MainActor.assumeIsolated { try runNavigationLifecycle() }
