import Foundation
import Testing
@testable import LogseqModel

private final class SyncAuthorizationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedActions: [String] = []
    private var recordedTokens: [String] = []

    func call(_ request: String) -> String {
        let json = try! JSONSerialization.jsonObject(with: Data(request.utf8)) as! [String: Any]
        let params = json["params"] as! [String: Any]
        let action = params["action"] as! String
        lock.lock()
        recordedActions.append(action)
        lock.unlock()
        let pending = action == "beginPendingSync" ? """
        {"id":1,"method":"POST","url":"https://example.com/sync/graph/tx/batch",
        "body":"{}","token":"expired-token","contentType":"application/json"}
        """ : "null"
        return """
        {"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],"pendingSyncRequest":\(pending)}}
        """
    }

    func send(_ request: LogseqPendingSyncRequest) -> LogseqPendingSyncResult {
        lock.lock()
        recordedTokens.append(request.token)
        lock.unlock()
        return LogseqPendingSyncResult(status: 200, body: "{}", error: nil)
    }

    var actions: [String] { lock.lock(); defer { lock.unlock() }; return recordedActions }
    var tokens: [String] { lock.lock(); defer { lock.unlock() }; return recordedTokens }
}

@Suite struct SyncAuthorizationTests {
    @Test @MainActor func pendingUploadUsesRefreshedAuthorization() async {
        let recorder = SyncAuthorizationRecorder()
        var refreshes = 0
        let store = LogseqStore(
            call: recorder.call,
            pendingTransport: { recorder.send($0) },
            syncTokenProvider: { refreshes += 1; return "refreshed-token" }
        )
        await store.syncPendingForBackground()
        #expect(refreshes == 1)
        #expect(recorder.tokens == ["refreshed-token"])
        #expect(recorder.actions == ["beginPendingSync", "completePendingSync"])
    }

    @Test @MainActor func failedRefreshCancelsUploadWithoutSendingExpiredCredentials() async {
        let recorder = SyncAuthorizationRecorder()
        let store = LogseqStore(
            call: recorder.call,
            pendingTransport: { recorder.send($0) },
            syncTokenProvider: { throw LogseqAuthenticationError.notSignedIn }
        )
        await store.syncPendingForBackground()
        #expect(recorder.tokens.isEmpty)
        #expect(recorder.actions == ["beginPendingSync", "cancelPendingSync"])
    }
}
