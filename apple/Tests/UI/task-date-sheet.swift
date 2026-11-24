import Observation
import SwiftUI
@testable import Logseq

// Launch with run-simulator-runtime-check.py in --interactive mode and an empty
// fixture directory, then run task-date-sheet.yaml against the same simulator.
@MainActor @Observable private final class TaskDateEffects: LGEffectExecuting {
    private let scheduled = 1_795_504_200_000
    private var deadline: Int? = 1_795_504_200_000
    var cleared = false
    private var deadlineValue: Any { deadline.map { $0 as Any } ?? NSNull() }

    func snapshot() throws -> String {
        try response([
            "selectedGraphId": "task-graph",
            "graphName": "Journals",
            "outlinerRows": [["depth": 0, "block": [
                "uuid": "note", "pageId": "today", "title": "Release notes",
                "journalTitle": "November 24", "journalDay": 20261124
            ]]],
            "journalTasks": [
                "graphId": "task-graph",
                "page": "today",
                "day": 20261124,
                "enabled": true,
                "success": true,
                "doing": [[
                    "uuid": "task",
                    "block": ["uuid": "task", "pageId": "older", "title": "Check the release date", "isTask": true],
                    "scheduled": scheduled,
                    "deadline": deadlineValue
                ]]
            ]
        ])
    }

    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        do {
            switch effect.kind {
            case "load-property-values":
                let input = try JSONSerialization.jsonObject(with: Data(effect.text.utf8)) as? [String: Any]
                guard let key = input?["key"] as? String else {
                    return .init(succeeded: false, message: "Expected a property catalog key")
                }
                let target: [String: Any] = ["uuid": "task", "scheduled": scheduled, "deadline": deadlineValue]
                let payload = try response(["propertyValues": ["key": key, "column": ["targets": [target]]]])
                return .init(succeeded: true, message: payload)
            case "node-property":
                let input = try JSONSerialization.jsonObject(with: Data(effect.text.utf8)) as? [String: Any]
                let changes = input?["changes"] as? [String: Any]
                guard changes?.count == 1, changes?["deadline"] is NSNull else {
                    return .init(succeeded: false, message: "Expected a deadline clear")
                }
                deadline = nil
                cleared = true
                return .init(succeeded: true, message: try snapshot())
            default:
                return .init(succeeded: true, message: "", output: .discard)
            }
        } catch {
            return .init(succeeded: false, message: String(describing: error))
        }
    }

    private func response(_ result: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
        return String(decoding: data, as: UTF8.self)
    }
}

@main struct TaskDateSheetCheck: App {
    @State private var coordinator = LGPlatformPresentationCoordinator()
    @State private var effects: TaskDateEffects
    @State private var runtime: LGRuntime
    @State private var started = false
    @State private var failure: String?

    init() {
        let effects = TaskDateEffects()
        _effects = State(initialValue: effects)
        _runtime = State(initialValue: LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects))
    }

    var body: some Scene {
        WindowGroup {
            LGRendererRoot(renderer: runtime.renderer)
                .overlay(alignment: .top) {
                    if let failure { Text(failure) }
                    if effects.cleared { Text("Deadline cleared") }
                }
                .modifier(LGPlatformPresentationHost(coordinator: coordinator, confirmOutlinerDelete: {}, stageAsset: { _ in }))
                .task {
                    guard !started else { return }
                    started = true
                    do {
                        try runtime.applyCoreResponse(effects.snapshot())
                        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
                        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
                    } catch {
                        failure = String(describing: error)
                    }
                }
        }
    }
}
