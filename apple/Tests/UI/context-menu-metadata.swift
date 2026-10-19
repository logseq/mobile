import Foundation
@testable import Logseq
@testable import LUIAppleBackend

@main struct ContextMenuMetadataCheck {
    @MainActor static func main() {
        do {
            try check()
        } catch {
            print("FAIL: context-menu metadata: \(error)")
            exit(1)
        }
    }

    @MainActor static func check() throws {
        for pointerEnabled in [false, true] {
            let renderer = LGRenderer()
            try renderer.apply(patchJSON: """
            {"generation":1,"ops":[
              {"op":"create-node","id":1,"kind":"button"},
              {"op":"set-prop","id":1,"property":"text","value":"Task"},
              {"op":"create-node","id":2,"kind":"context-menu"},
              {"op":"create-node","id":3,"kind":"menu-item"},
              {"op":"set-prop","id":3,"property":"text","value":"Todo"},
              {"op":"set-prop","id":3,"property":"press-enabled","value":true},
              {"op":"set-prop","id":3,"property":"pointer-enabled","value":\(pointerEnabled)},
              {"op":"insert-child","parent":1,"child":2,"index":0},
              {"op":"insert-child","parent":2,"child":3,"index":0}
            ]}
            """)
            var pressed = false
            renderer.onEvent = { event in
                if event.kind == .press, event.nodeID == 3 { pressed = true }
            }
            try renderer.backend.performPress(node: 3)
            guard pressed else { fatalError("Context-menu action did not dispatch") }
            do {
                try renderer.apply(patchJSON: """
                {"generation":2,"ops":[
                  {"op":"set-prop","id":3,"property":"font-size","value":18}
                ]}
                """)
                fatalError("Context menu accepted unsupported layout metadata")
            } catch {
                print("PASS: pointer-enabled=\(pointerEnabled), action dispatch and metadata validation")
            }
        }
    }
}

@_cdecl("logseq_initialize") func unexpectedCoreInitialization() { fatalError("Unexpected core initialization") }
