import Foundation
import LogseqModel

private final class SocketRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var forwarded = false
    let url: String
    init(url: String) { self.url = url }

    func call(_ request: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let envelope = try! JSONSerialization.jsonObject(with: Data(request.utf8)) as! [String: Any]
        let params = envelope["params"] as! [String: Any]
        let commands: [[String: Any]]
        if params["action"] as? String == "beginSyncTransport" {
            commands = [["type": "connect", "url": url]]
        } else {
            let payload = try! JSONSerialization.jsonObject(with: Data((params["payload"] as! String).utf8)) as! [String: Any]
            precondition(payload["generation"] as? Int == 7 && payload["graphId"] as? String == "plain-1")
            switch payload["type"] as! String {
            case "opened": commands = [["type": "send", "body": "opaque outbound body"]]
            case "frame":
                precondition(payload["body"] as? String == "opaque wire payload")
                forwarded = true
                commands = [["type": "close"], ["type": "retry", "delayMs": 1500]]
            default: fatalError("Unexpected socket event: \(payload)")
            }
        }
        return String(data: try! JSONSerialization.data(withJSONObject: [
            "apiVersion": 1, "ok": true, "result": ["revision": 1, "blocks": [],
                "syncTransport": ["generation": 7, "graphId": "plain-1", "commands": commands]],
        ]), encoding: .utf8)!
    }

    func didForward() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return forwarded
    }
}

@main struct SyncCommandExecutionCheck {
    @MainActor static func main() async throws {
        let response = #"{"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],"syncTransport":{"generation":7,"graphId":"plain-1","snapshotRequired":true,"commands":[{"type":"retry","delayMs":2300}]}}}"#
        let store = LogseqStore { _ in response }
        let snapshotRequired = await store.runGraphEventsOnce(
            graphID: "plain-1", baseURL: "http://localhost", accessToken: "token"
        )
        guard !snapshotRequired else { fatalError("A retry command must not refresh the snapshot while editing") }
        guard store.graphEventsRetryDelayMilliseconds == 2300 else { fatalError("The native loop must preserve the core retry delay") }
        print("PASS: core retry command defers snapshot recovery")
        if CommandLine.arguments.count > 1 {
            let recorder = SocketRecorder(url: CommandLine.arguments[1])
            let socketStore = LogseqStore { recorder.call($0) }
            let refresh = await socketStore.runGraphEventsOnce(
                graphID: "plain-1", baseURL: "unused", accessToken: "test-token"
            )
            precondition(!refresh && recorder.didForward())
            precondition(socketStore.graphEventsRetryDelayMilliseconds == 1500)
            print("PASS: native socket sends core bytes and forwards opaque frames with generation")
        }
    }
}
