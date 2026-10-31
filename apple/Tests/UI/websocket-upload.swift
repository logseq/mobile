import Foundation
import LogseqModel

private final class UploadCore: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var attempts = 0
    private var httpCalls = 0
    private var completion: [String: Any]?
    let url: String
    init(_ url: String) { self.url = url }
    func recordHTTP() -> LogseqPendingSyncResult {
        lock.lock(); defer { lock.unlock() }
        httpCalls += 1
        return LogseqPendingSyncResult(status: nil, body: nil, error: "Unexpected HTTP upload")
    }
    func result() -> (Int, [String: Any]?) {
        lock.lock(); defer { lock.unlock() }
        return (httpCalls, completion)
    }
    func call(_ wire: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let input = try! JSONSerialization.jsonObject(with: Data(wire.utf8)) as! [String: Any]
        let params = input["params"] as! [String: Any]
        let action = params["action"] as? String ?? ""
        let payload = (params["payload"] as? String).flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        } ?? [:]
        var commands: [[String: Any]] = []
        var pending: Any = NSNull()
        switch action {
        case "beginSyncTransport": commands = [["type": "connect", "url": url]]
        case "syncTransportEvent":
            switch payload["type"] as? String {
            case "opened": commands = [["type": "send", "body": "subscribe"], ["type": "sync-pending"]]
            case "frame":
                commands = [["type": "pending-result", "id": 1, "body": payload["body"]!], ["type": "sync-pending"]]
            case "failed": commands = [["type": "close"], ["type": "retry", "delayMs": 1000]]
            default: break
            }
        case "beginPendingSync":
            if !completed {
                attempts += 1
                pending = ["id": 1, "method": "WS", "url": url,
                    "body": #"{"type":"tx/batch","t-before":41,"txs":[]}"#,
                    "token": "test-token", "filePath": NSNull(), "contentType": "application/json"] as [String: Any]
            }
        case "completePendingSync": completion = payload; completed = true
        default: break
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: [
            "apiVersion": 1, "ok": true, "result": ["revision": attempts, "blocks": [],
            "pendingSyncRequest": pending,
            "syncTransport": ["generation": 1, "graphId": "graph", "commands": commands]]]), as: UTF8.self)
    }
}

@main struct WebSocketUploadCheck {
    @MainActor static func main() async throws {
        let url = CommandLine.arguments[1], mode = CommandLine.arguments[2]
        let core = UploadCore(url)
        let store = LogseqStore(call: { core.call($0) }, pendingTransport: { _ in core.recordHTTP() })
        let task = Task { await store.runGraphEventsOnce(graphID: "graph", baseURL: "unused", accessToken: "test-token",
            stopAfterFirstFrame: mode == "background") }
        let deadline = Date().addingTimeInterval(8)
        while core.result().1 == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let (httpCalls, completion) = core.result()
        if mode != "background" { task.cancel() }
        _ = await task.value
        precondition(httpCalls == 0, "Graph transactions must use the active socket, never the HTTP transport")
        precondition(completion != nil, "A socket response or disconnect must settle the pending request")
        if mode == "disconnect" {
            precondition(completion?["error"] as? String != nil, "Disconnect must release the waiting upload")
        } else {
            precondition(completion?["status"] as? Int == 200)
            let body = try JSONSerialization.jsonObject(with: Data((completion?["body"] as! String).utf8)) as! [String: Any]
            precondition(body["type"] as? String == (mode == "reject" ? "tx/reject" : "tx/batch/ok"))
        }
        print("PASS: websocket upload \(mode)")
    }
}
