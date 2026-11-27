// Run with run-simulator-runtime-check.py in --interactive mode and an empty
// fixture directory, then run journal-home-reselect.yaml on that simulator.
import SwiftUI
@testable import Logseq

@MainActor private final class JournalHomeTapEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct JournalHomeReselectFixture: App {
    private let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: JournalHomeTapEffects())

    init() {
        let rows = (0..<120).map { index in
            ["depth": 0, "block": ["uuid": "home-tap-\(index)", "pageId": "journal",
                "title": index == 0 ? "First journal block" : "Journal block \(index)"]] as [String: Any]
        }
        let payload = try! JSONSerialization.data(withJSONObject: ["ok": true, "result": [
            "selectedGraphId": "journal-home-tap", "graphName": "Journal", "outlinerRows": rows
        ]])
        try! runtime.applyCoreResponse(String(decoding: payload, as: UTF8.self))
        try! runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try! runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
    }

    var body: some Scene {
        WindowGroup { LGRendererRoot(renderer: runtime.renderer) }
    }
}
