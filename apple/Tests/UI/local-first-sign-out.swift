import Foundation
import SQLite3
import LogseqModel
@testable import LUIAppleBackend
@testable import Logseq

@main struct LocalFirstSignOutCheck {
    @MainActor static func main() async throws {
        let defaults = UserDefaults.standard
        let graphID = "offline-local"
        let session = #"{"graphId":"offline-local","destination":"journals","appPath":[],"searchPath":[],"selectedPageId":null,"recentGraphIds":[]}"#
        defaults.set(graphID, forKey: "logseq.selectedGraphId")
        defaults.set(session, forKey: "logseq.uiSession")
        let runtime = LogseqLogseqRuntime.shared
        try FileManager.default.createDirectory(at: URL.documentsDirectory, withIntermediateDirectories: true)
        let catalog = #"{"graphs":[{"graph-id":"offline-local","graph-name":"Offline local","graph-e2ee?":false,"graph-ready-for-use?":true}]}"#
        let envelope = String(decoding: try JSONSerialization.data(withJSONObject:
            ["^ ", "~:format-version", 1, "~:value-type", "~:string", "~:value", catalog]), as: UTF8.self)
        var database: OpaquePointer?
        guard sqlite3_open(runtime.databasePath, &database) == SQLITE_OK else { throw failure("Cannot prepare catalog") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE TABLE IF NOT EXISTS kvs (address TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL)", nil, nil, nil) == SQLITE_OK else {
            throw failure("Cannot create catalog table")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO kvs (address,payload) VALUES ('logseq/graph-catalog/v1',?)", -1, &statement, nil) == SQLITE_OK else {
            throw failure("Cannot prepare catalog row")
        }
        _ = envelope.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure("Cannot save catalog row") }
        sqlite3_finalize(statement)
        _ = LogseqStore.callForLaunch(LogseqRPCRequest(method: "open",
            params: LogseqRPCParams(action: nil, path: runtime.databasePath)))
        let configured = LogseqStore.callForLaunch(LogseqRPCRequest(method: "dispatch",
            params: LogseqRPCParams(action: "configure", payload:
                #"{"baseUrl":"https://api.logseq.io","graphId":"offline-local","graphName":"Offline local","token":""}"#)))
        runtime.startLGRenderer()
        runtime.store.applyLaunchResponse(configured, actionName: "configure", databasePath: runtime.databasePath)
        try runtime.lgRuntime.applyHostUpdate(kind: "local-graph-ids", payload: #"["offline-local"]"#)
        try runtime.lgRuntime.applyHostUpdate(kind: "authentication", payload: #"{"state":"signedIn","errorMessage":null}"#)
        try runtime.lgRuntime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.lgRuntime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func press(_ identifier: String) async throws {
            for _ in 0..<100 {
                if let id = find(identifier) {
                    try backend.performPress(node: id)
                    await runtime.lgRuntime.drainEffectsForTesting()
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure("Missing control: " + identifier)
        }
        try await press("button.sidebar")
        try await press("button.sidebar.settings")
        try await press("button.sign-out")
        try await press("button.sign-out.confirm")
        guard defaults.string(forKey: "logseq.selectedGraphId") == graphID,
              defaults.string(forKey: "logseq.uiSession") == session,
              runtime.store.snapshot.selectedGraphId == graphID else {
            throw failure("Sign-out discarded the local graph or navigation state")
        }
        guard find("screen.authentication") == nil, find("pane.journals") != nil else {
            throw failure("The local graph is hidden by authentication after sign-out")
        }
        let snapshot = LogseqStore.callForLaunch(LogseqRPCRequest(method: "snapshot", params: LogseqRPCParams(action: nil)))
        let response = try JSONDecoder().decode(LogseqRPCResponse.self, from: Data(snapshot.utf8))
        guard response.result?.selectedGraphId == graphID else {
            throw failure("Core configuration lost the local graph after logout")
        }
        print("PASS: real sign-out preserves selected graph, UI session, local journals, and core graph configuration")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "LocalFirstSignOut", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
