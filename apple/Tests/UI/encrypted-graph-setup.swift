import Foundation
import LogseqModel

@main struct EncryptedGraphSetupCheck {
    @MainActor static func main() async throws {
        func call(_ action: String, _ payload: String? = nil) throws -> LogseqRPCResponse {
            let source = LogseqStore.callForLaunch(LogseqRPCRequest(
                method: "dispatch", params: LogseqRPCParams(action: action, payload: payload)))
            return try JSONDecoder().decode(LogseqRPCResponse.self, from: Data(source.utf8))
        }
        _ = LogseqStore.callForLaunch(LogseqRPCRequest(method: "open", params: LogseqRPCParams(
            action: nil, path: URL.documentsDirectory.appendingPathComponent("encryption.sqlite").path)))
        let config = #"{"baseUrl":"__SELF_HOSTED_BASE_URL__","graphId":"","token":"fixture-token"}"#
        let configured = try call("configure", config)
        precondition(configured.ok)
        let first = try call("createSyncGraph", #"{"name":"Private","isEncrypted":true}"#)
        precondition(first.error?.code == "e2ee_password_required",
                     "First encrypted graph must request setup before creating anything: \(String(describing: first.error))")
        let blank = try call("createSyncGraph", #"{"name":"Private","isEncrypted":true,"password":"   "}"#)
        precondition(blank.error?.code == "e2ee_password_required", "Blank passwords must not initialize encryption")
        for token in ["fixture-denied", "fixture-malformed", "fixture-upload-failure"] {
            let failureConfig = config.replacingOccurrences(of: "fixture-token", with: token)
            let configured = try call("configure", failureConfig)
            precondition(configured.ok)
            let rejected = try call("createSyncGraph", #"{"name":"Private","isEncrypted":true,"password":"correct horse battery staple"}"#)
            precondition(rejected.error?.code == "e2ee_user_keys_failed",
                         "Account key errors must stop before graph creation: \(String(describing: rejected.error))")
        }
        let reconfigured = try call("configure", config)
        precondition(reconfigured.ok)
        let created = try call("createSyncGraph", #"{"name":"Private","isEncrypted":true,"password":"correct horse battery staple"}"#)
        precondition(created.ok && created.result?.isGraphUnlocked == true,
                     "First encrypted graph must initialize account keys and provision its key: \(String(describing: created.error))")
        let second = try call("createSyncGraph", #"{"name":"Second","isEncrypted":true}"#)
        precondition(second.ok, "Existing account keys must be reused without a new password")
        let plain = try call("createSyncGraph", #"{"name":"Plain","isEncrypted":false}"#)
        precondition(plain.ok, "Plain graphs must keep working")
        print("PASS: encrypted creation initializes account keys once and reuses them")
    }
}
