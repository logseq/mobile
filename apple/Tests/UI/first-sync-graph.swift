import Foundation
import LogseqModel
@testable import Logseq

@main struct FirstSyncGraphCheck {
    @MainActor static func main() async throws {
        let defaults = UserDefaults.standard
        defaults.set("__SELF_HOSTED_BASE_URL__", forKey: "logseq.baseURL")
        defaults.removeObject(forKey: "logseq.selectedGraphId")
        defaults.removeObject(forKey: "logseq.uiSession")

        let runtime = LogseqLogseqRuntime.shared
        runtime.startLocalLaunchLoad()
        runtime.startLocalLaunchLoad()
        precondition(runtime.store.snapshot.selectedGraphId == nil,
                     "First launch must keep the graph catalog unselected")

        let validation = LogseqStore.callForLaunch(LogseqRPCRequest(
            method: "dispatch",
            params: LogseqRPCParams(action: "createSyncGraph", payload: "{}")
        ))
        let response = try JSONDecoder().decode(LogseqRPCResponse.self, from: Data(validation.utf8))
        precondition(response.error?.code == "invalid_params",
                     "Cold launch without a selected graph must configure the core before graph creation: \(validation)")

        let created = await runtime.store.createSyncGraph(name: "First self-hosted graph", isEncrypted: false)
        precondition(!created && runtime.store.lastError?.code == "graph_create_failed"
                     && runtime.store.lastError?.message.contains("self-hosted-creation-reached") == true,
                     "Graph creation must reach the saved server: \(String(describing: runtime.store.lastError))")
        precondition(runtime.authentication.state == .restoring,
                     "Local startup must configure the server without requiring hosted authentication")
        print("PASS: first-graph cold launch configures the saved server before creation")
    }
}
