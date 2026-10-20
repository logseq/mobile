import Foundation
import LogseqModel

private final class PumpRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = 0
    func call(_ request: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let input = try! JSONSerialization.jsonObject(with: Data(request.utf8)) as! [String: Any]
        let action = (input["params"] as! [String: Any])["action"] as! String
        if action == "completePendingSync" { completed += 1 }
        let pending: Any = completed < 2 ? ["id": 1, "method": "POST", "url": "https://unused.test/request",
            "body": "stable transaction", "token": "token", "contentType": "application/json", "delayMs": completed == 1 ? 100 : 0] : NSNull()
        return String(data: try! JSONSerialization.data(withJSONObject: ["apiVersion": 1, "ok": true,
            "result": ["revision": 1, "blocks": [], "pendingSyncRequest": pending,
                "pendingSyncError": completed == 1 ? "retrying" as Any : NSNull()]]), encoding: .utf8)!
    }
}

private actor Transport {
    private var requests: [LogseqPendingSyncRequest] = []
    private var times: [ContinuousClock.Instant] = []
    func send(_ request: LogseqPendingSyncRequest) -> LogseqPendingSyncResult {
        requests.append(request)
        times.append(.now)
        return LogseqPendingSyncResult(status: requests.count == 1 ? 503 : 200, body: "{}", error: nil)
    }
    func verify() -> Bool {
        requests.count == 2 && requests[0].body == requests[1].body && requests[0].id == requests[1].id
            && times[0].duration(to: times[1]) >= .milliseconds(80)
    }
}

@main struct PendingCommandExecutionCheck {
    @MainActor static func main() async {
        let recorder = PumpRecorder()
        let transport = Transport()
        let store = LogseqStore(call: { recorder.call($0) }, pendingTransport: { await transport.send($0) })
        await store.syncPendingForBackground()
        let verified = await transport.verify()
        precondition(verified, "The native pump must execute the core retry and its delay")
        precondition(store.syncError == nil, "The successful core completion must clear the retry error")
        print("PASS: native pending pump executes the core retry delay and preserves request identity")
    }
}
