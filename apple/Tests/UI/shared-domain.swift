import Foundation
import LogseqModel
@testable import Logseq

@main struct SharedDomainCheck {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("capture.sqlite").path
        func decode(_ source: String) throws -> LogseqSnapshot {
            let response = try JSONDecoder().decode(LogseqRPCResponse.self, from: Data(source.utf8))
            precondition(response.ok, "Core error: \(String(describing: response.error))")
            return response.result!
        }
        let store = LogseqStore(call: { LogseqCore.shared.logseq_call($0) }, pendingTransport: { _ in
            LogseqPendingSyncResult(status: nil, body: nil, error: "Offline integration fixture")
        })
        await store.openAndWait(path: path)
        await store.configureAndSelectGraph(baseURL: "__SELF_HOSTED_BASE_URL__", token: "fixture-token", selectedGraphID: nil)
        let created = await store.createSyncGraph(name: "Native domain", isEncrypted: false)
        precondition(created, "\(String(describing: store.lastError))")
        let graphID = store.snapshot.selectedGraphId!
        let bootstrapped = await store.bootstrapSelectedGraph(
            graphID: graphID, baseURL: "__SELF_HOSTED_BASE_URL__", accessToken: "fixture-token")
        precondition(bootstrapped, "\(String(describing: store.lastError))")
        let executor = LGCoreEffectExecutor()
        func snapshot() async throws -> LogseqSnapshot {
            try decode(await LogseqCore.callAsync(LogseqRPCRequest(
                method: "snapshot", params: LogseqRPCParams(action: nil, projection: "snapshot"))))
        }
        func execute(_ kind: String, text: String, metadata: String? = nil) async throws -> (String, LogseqSnapshot) {
            let result = await executor.execute(LGEffect(id: 1, kind: kind, text: text, metadata: metadata))
            precondition(result.succeeded, result.message)
            return (result.message, try await snapshot())
        }
        let (_, captured) = try await execute("send-capture", text: "Native shared capture 中文")
        let block = captured.blocks.first { $0.title == "Native shared capture 中文" }
        precondition(block != nil, "The real core must expose the new capture: \(captured)")
        let metadata = #"{"uuid":"todo","ident":"logseq.property/status.todo","title":"Todo"}"#
        let (_, task) = try await execute("send-task", text: "Native shared task", metadata: metadata)
        precondition(task.blocks.contains { $0.title == "Native shared task" && $0.status?.title == "Todo" })
        let (_, asset) = try await execute("send-asset", text:
            #"{"uuid":"00000000-0000-4000-8000-000000000001","title":"recording.m4a","assetType":"m4a","assetSize":12,"assetChecksum":"abc","localPath":"Assets/recording.m4a","transcript":"Native transcript","transcriptUUID":"00000000-0000-4000-8000-000000000002"}"#)
        precondition(asset.blocks.contains { $0.uuid == "00000000-0000-4000-8000-000000000002" && $0.parentId == "00000000-0000-4000-8000-000000000001" })
        await store.openAndWait(path: path)
        await store.configureAndSelectGraph(baseURL: "__SELF_HOSTED_BASE_URL__", token: "fixture-token", selectedGraphID: graphID)
        let restored = await store.bootstrapSelectedGraph(
            graphID: graphID, baseURL: "__SELF_HOSTED_BASE_URL__", accessToken: "fixture-token", allowSnapshotDownload: false)
        precondition(restored, "\(String(describing: store.lastError))")
        let reopened = try await snapshot()
        precondition(reopened.blocks.contains { $0.uuid == block!.uuid && $0.title == block!.title })
        precondition(reopened.blocks.contains { $0.uuid == "00000000-0000-4000-8000-000000000002" })
        print("PASS: native effects persist captures, tasks and transcript children through the real OCaml core")

        let native = LogseqCore.shared
        let initialPatch = native.logseq_lui_initialize(2, 2, 3)
        let fullResponse = await LogseqCore.callAsync(LogseqRPCRequest(
            method: "snapshot", params: LogseqRPCParams(action: nil, projection: "snapshot")))
        let snapshotPatch = native.logseq_lui_apply_snapshot(fullResponse)
        let (response, _) = try await execute("tap-outliner-block", text: block!.uuid)
        let patch = native.logseq_lui_apply_snapshot(response)
        let operations: [[String: Any]] = try [initialPatch, snapshotPatch, patch].filter { !$0.isEmpty }.flatMap {
            let json = try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            return json["ops"] as? [[String: Any]] ?? []
        }
        let policy = operations.first { $0["property"] as? String == "input-policy" }?["value"] as? String
        precondition(policy != nil, "The real LUI editor must provide its input policy: \(patch)")
        let deletion = NativeEditorInputPolicy.deletingEmptyPair(
            from: "😀[[]]", range: NSRange(location: 3, length: 1), replacementText: "", inputPolicy: policy!)
        precondition(deletion?.text == "😀" && deletion?.caretUTF16Offset == 2)
        let selected = NativeEditorInputPolicy.deletingEmptyPair(
            from: "😀[[]]", range: NSRange(location: 2, length: 2), replacementText: "", inputPolicy: policy!)
        precondition(selected == nil)
        _ = native.logseq_lui_dispose()
        print("PASS: native editor applies the actual core-issued input policy at UTF-16 boundaries")
    }
}
