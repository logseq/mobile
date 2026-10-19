import Foundation
@testable import Logseq
@testable import LUIAppleBackend

@main struct LaunchRendererCheck {
    @MainActor static func main() throws {
        let native = LaunchNativeProbe()
        let runtime = LGRuntime(native: native)
        try runtime.applyCoreResponse("local graph response")
        try runtime.applyHostUpdate(kind: "local-graph-ids", payload: "[]")
        try runtime.start(platformCode: 2)
        guard runtime.renderer.backend.model(id: 2)?.property(.text)?.stringValue == "Journals" else {
            print("FAIL: startup returned with the graph picker instead of the local journals")
            exit(1)
        }
        guard runtime.renderer.backend.model(id: 3)?.property(.text)?.stringValue == "Local graph",
              runtime.renderer.backend.coalescesCommits else {
            print("FAIL: startup host state was delayed or live commit coalescing was lost")
            exit(1)
        }
        guard native.appliedSnapshots == ["local graph response"] else {
            print("FAIL: local startup response was not applied exactly once")
            exit(1)
        }
        print("PASS: first renderer state contains the local journals synchronously")
    }
}

private final class LaunchNativeProbe: LGNativeCalling {
    var initialPatch = """
    {"generation":1,"ops":[
      {"op":"create-node","id":1,"kind":"root"},
      {"op":"create-node","id":4,"kind":"column"},
      {"op":"insert-child","parent":1,"child":4,"index":0},
      {"op":"create-node","id":2,"kind":"text"},
      {"op":"set-prop","id":2,"property":"text","value":"Choose a graph"},
      {"op":"insert-child","parent":4,"child":2,"index":0},
      {"op":"create-node","id":3,"kind":"text"},
      {"op":"set-prop","id":3,"property":"text","value":"Catalog"},
      {"op":"insert-child","parent":4,"child":3,"index":1}
    ]}
    """
    var appliedSnapshots: [String] = []

    func initialize(
        platformCode: Int,
        hostCode: Int,
        authenticationCode: Int
    ) -> String {
        return initialPatch
    }

    func appear(node: Int) -> String { "" }

    func press(node: Int) -> String { "" }
    func longPress(node: Int) -> String { "" }
    func textChanged(node: Int, text: String) -> String { "" }
    func submit(node: Int) -> String { "" }
    func toggleChanged(node: Int, checked: Bool) -> String { "" }
    func change(node: Int) -> String { "" }
    func valueChanged(node: Int, value: Double) -> String { "" }
    func dismiss(node: Int) -> String { "" }
    func doublePress(node: Int) -> String { "" }
    func picked(node: Int, payload: String) -> String { "" }
    func visibleRange(node: Int, first: Int, last: Int) -> String { "" }
    func scrollCompleted(node: Int, token: Int, outcome: String) -> String { "" }
    func extensionEvent(
        node: Int,
        identifier: String,
        name: String,
        text: String,
        value: Int
    ) -> String {
        return ""
    }
    func dispose() -> String { "" }
    func takeEffect() -> String { "" }
    func resolveEffect(id: Int, succeeded: Bool, message: String) -> String {
        return ""
    }
    func applySnapshot(_ response: String) -> String {
        appliedSnapshots.append(response)
        return """
        {"generation":2,"ops":[
          {"op":"set-prop","id":2,"property":"text","value":"Journals"}
        ]}
        """
    }
    func applyHostUpdate(kind: String, payload: String) -> String {
        return """
        {"generation":3,"ops":[
          {"op":"set-prop","id":3,"property":"text","value":"Local graph"}
        ]}
        """
    }
}

@_cdecl("logseq_initialize") func unexpectedCoreInitialization() { fatalError("Unexpected core initialization") }
