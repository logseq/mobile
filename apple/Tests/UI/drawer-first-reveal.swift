import SwiftUI
import UIKit
@testable import LUIAppleBackend

@MainActor private final class ProbeState {
    var visibleInstances = Set<UUID>()
    var labels: [String] = []
}

private struct PanelProbe: View {
    let state: ProbeState
    let label: String
    @State private var identity = UUID()
    var body: some View {
        Text(label).onAppear {
            state.visibleInstances.insert(identity)
            state.labels.append(label)
        }
    }
}

@main struct DrawerFirstRevealCheck {
    @MainActor static func main() async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "DrawerFirstReveal", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        for initiallyOpen in [false, true] {
            let state = ProbeState()
            let registry = LUIAppleExtensionRegistry()
            try registry.register(LUIAppleExtension(identifier: "panel-probe", fingerprint: "probe-v1",
                properties: [.init(name: "label", kind: .string, isRequired: true)]) { context in
                let label: String
                if case let .string(value) = context.property("label") { label = value } else { label = "" }
                return AnyView(PanelProbe(state: state, label: label))
            })
            let backend = try LUIAppleBackend(extensionRegistry: registry)
            try backend.apply(json: """
            {"generation":1,"ops":[
              {"op":"create-node","id":1,"kind":"drawer"},
              {"op":"set-prop","id":1,"property":"selected","value":\(initiallyOpen)},
              {"op":"create-node","id":2,"kind":"text"},
              {"op":"set-prop","id":2,"property":"text","value":"Main content"},
              {"op":"create-extension","id":3,"identifier":"panel-probe","fingerprint":"probe-v1"},
              {"op":"set-extension-prop","id":3,"property":"label","value":"Current sidebar"},
              {"op":"insert-child","parent":1,"child":2,"index":0},
              {"op":"insert-child","parent":1,"child":3,"index":1}
            ]}
            """)
            let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow }!
            let window = UIWindow(windowScene: previous.windowScene!)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            let host = UIHostingController(rootView: LUISwiftUIRoot(backend: backend, rootID: 1)
                .environment(\.horizontalSizeClass, .compact))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; previous.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(150))
            try require(state.visibleInstances.count == (initiallyOpen ? 1 : 0),
                "A closed drawer must not mount its hidden panel at launch")
            if !initiallyOpen {
                try backend.apply(json: #"{"generation":2,"ops":[{"op":"set-extension-prop","id":3,"property":"label","value":"Updated before reveal"}]}"#)
                try backend.apply(json: #"{"generation":3,"ops":[{"op":"set-prop","id":1,"property":"selected","value":true}]}"#)
                try await Task.sleep(for: .milliseconds(450))
                try require(state.labels.last == "Updated before reveal", "First reveal must use current panel data")
            }
            try require(state.visibleInstances.count == 1, "Opening a drawer must mount its native panel")
            try backend.apply(json: #"{"generation":4,"ops":[{"op":"set-prop","id":1,"property":"selected","value":false}]}"#)
            try await Task.sleep(for: .milliseconds(450))
            try backend.apply(json: #"{"generation":5,"ops":[{"op":"set-prop","id":1,"property":"selected","value":true}]}"#)
            try await Task.sleep(for: .milliseconds(450))
            try require(state.visibleInstances.count == 1, "Closing and reopening must preserve panel state")
        }
        print("PASS: closed drawers defer panel creation, first reveal uses fresh data, reopening preserves state")
    }
}
