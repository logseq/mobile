import Foundation
import SwiftUI
import LogseqModel
@testable import Logseq
@testable import LUIAppleBackend

// Run with an isolated graph from shared/bench/page_fixture.exe.
@main struct HostSnapshotProjectionCheck: App {
    var body: some Scene {
        WindowGroup {
            Text("Host snapshot projection check").task {
                do {
                    try await Self.check()
                    print("RUNTIME_CHECK_COMPLETE")
                    exit(0)
                } catch {
                    print("RUNTIME_CHECK_FAILED: \(error)")
                    exit(1)
                }
            }
        }
    }

    @MainActor private static func check() async throws {
        func call(_ method: String = "dispatch", action: String? = nil,
                  payload: String? = nil, path: String? = nil) -> String {
            LogseqStore.callForLaunch(LogseqRPCRequest(method: method,
                params: LogseqRPCParams(action: action, payload: payload, path: path)))
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "HostSnapshotProjection", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let documents = URL.documentsDirectory
        let database = documents.appendingPathComponent("logseq.sqlite").path
        let catalog = call("open", path: database)
        _ = call(action: "configure", payload: #"{"graphId":"uiregression","baseUrl":"http://127.0.0.1:1","token":""}"#)
        let graph = documents.appendingPathComponent("graphs/uiregression")
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: [
            "graphId": "uiregression", "activePath": graph.appendingPathComponent("graph.sqlite").path,
            "checkpointPath": graph.appendingPathComponent("sync.checkpoint").path, "isEncrypted": false
        ]), as: UTF8.self)
        _ = call(action: "openGraph", payload: payload)
        let response = call(action: "selectPage", payload: "6954ee2a-506b-4dd9-bd6d-0dc24db9c055")
        let decoded = try JSONDecoder().decode(LogseqRPCResponse.self, from: Data(response.utf8))
        try require(decoded.ok && (decoded.result?.blocks.count ?? 0) >= 20,
            "The fixture must contain real, nonempty page content")
        let full = LogseqStore(call: { LogseqCore.shared.logseq_call($0) })
        full.applyLaunchResponse(response, actionName: "selectPage", databasePath: database)
        try require(full.snapshot.blocks.count == decoded.result?.blocks.count,
            "Standalone model consumers must retain full snapshot compatibility")
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(
            callCore: { await LogseqCore.callAsync($0) },
            platformEffect: { _ in LGEffectResolution(succeeded: true, message: "", output: .discard) }))
        var observedResponse = ""
        let host = LogseqStore(call: { LogseqCore.shared.logseq_call($0) }, responseObserver: { json in
            observedResponse = json
            try! runtime.applyCoreResponse(json)
        }, projection: .hostMetadata)
        host.applyLaunchResponse(response, actionName: "selectPage", databasePath: database)
        try require(host.snapshot.blocks.isEmpty && host.snapshot.outlinerRows.isEmpty && host.snapshot.nodeRoutes.isEmpty,
            "The native host must not decode a second copy of UI-owned blocks and outline rows")
        try require(host.snapshot.selectedGraphId == full.snapshot.selectedGraphId
            && host.snapshot.isGraphUnlocked == full.snapshot.isGraphUnlocked
            && host.snapshot.appliedServerT == full.snapshot.appliedServerT,
            "The lightweight host projection must preserve graph and synchronization state")
        try require(observedResponse == response, "The UI must receive the original complete core response")
        try runtime.applyHostUpdate(kind: "local-graph-ids", payload: #"["uiregression"]"#)
        try runtime.start(platformCode: 2, authenticationCode: 3)
        let backend = runtime.renderer.backend
        func ids(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(ids)
        }
        try require(backend.rootIDs.flatMap(ids).contains {
            backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == "outliner.block.e2e30000-0000-4000-9000-000000001000"
        }, "Skipping duplicate host decoding must preserve the real rendered page blocks")
        host.applyLaunchResponse(catalog, actionName: "open", databasePath: database)
        try require(host.snapshot.graphs?.first?.id == "uiregression",
            "Catalog graph names and encryption metadata must remain available")
        print("PASS: host metadata avoids duplicate UI models while real page rendering and graph state remain intact")
    }
}
