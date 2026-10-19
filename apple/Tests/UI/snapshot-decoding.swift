import Foundation
import SwiftUI
import LogseqModel
@testable import Logseq

@main struct SnapshotDecodingCheck: App {
    var body: some Scene {
        WindowGroup {
            Text("Snapshot protocol check").task {
                do {
                    func call(_ method: String = "dispatch", action: String? = nil, payload: String? = nil, path: String? = nil) -> String {
                        LogseqStore.callForLaunch(LogseqRPCRequest(method: method,
                            params: LogseqRPCParams(action: action, payload: payload, path: path)))
                    }
                    let documents = URL.documentsDirectory
                    _ = call("open", path: documents.appendingPathComponent("logseq.sqlite").path)
                    _ = call(action: "configure", payload: #"{"graphId":"uiregression","baseUrl":"http://127.0.0.1:1","token":""}"#)
                    let graph = documents.appendingPathComponent("graphs/uiregression")
                    let payload = String(decoding: try JSONSerialization.data(withJSONObject: [
                        "graphId": "uiregression", "activePath": graph.appendingPathComponent("graph.sqlite").path,
                        "checkpointPath": graph.appendingPathComponent("sync.checkpoint").path, "isEncrypted": false
                    ]), as: UTF8.self)
                    _ = call(action: "openGraph", payload: payload)
                    _ = call(action: "loadSidebar")
                    for action in ["selectPage", "snapshot", "stopWebSocket"] {
                        let response = action == "snapshot" ? call("snapshot")
                            : call(action: action, payload: action == "selectPage" ? "6954ee2a-506b-4dd9-bd6d-0dc24db9c055" : nil)
                        let decoded = try JSONDecoder().decode(LogseqRPCResponse.self, from: Data(response.utf8))
                        precondition(decoded.ok && (decoded.result?.outlinerRows.count ?? 0) == 10_000,
                                     "Every native snapshot consumer must accept the complete large-page projection")
                        print("PASS: Swift model decoded \(action) with 10k outline rows")
                    }
                    print("RUNTIME_CHECK_COMPLETE")
                    exit(0)
                } catch {
                    print("RUNTIME_CHECK_FAILED: \(error)")
                    exit(1)
                }
            }
        }
    }
}
