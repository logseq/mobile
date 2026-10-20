import Foundation
import LogseqModel

private final class RecoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    let url: String
    init(url: String) { self.url = url }
    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
    func call(_ request: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let envelope = try! JSONSerialization.jsonObject(with: Data(request.utf8)) as! [String: Any]
        let params = envelope["params"] as! [String: Any]
        let commands: [[String: Any]]
        if params["action"] as? String == "beginSyncTransport" {
            commands = [["type": "connect", "url": url]]
        } else {
            let event = try! JSONSerialization.jsonObject(with: Data((params["payload"] as! String).utf8)) as! [String: Any]
            let type = event["type"] as! String
            events.append(type)
            switch type {
            case "opened": commands = [["type": "send", "body": "subscribe"]]
            case "failed": commands = [["type": "close"], ["type": "retry", "delayMs": 1000]]
            case "cancelled": commands = [["type": "close"]]
            default: commands = []
            }
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: [
            "apiVersion": 1, "ok": true, "result": ["revision": 1, "blocks": [],
            "syncTransport": ["generation": 1, "graphId": "graph", "commands": commands]]]), as: UTF8.self)
    }
}

@main struct IdleRecoveryCheck {
    @MainActor static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        let mode = environment["LOGSEQ_TEST_SOCKET_MODE"] ?? CommandLine.arguments[2]
        let url = environment["LOGSEQ_TEST_SOCKET_URL"] ?? CommandLine.arguments[1]
        let recorder = RecoveryRecorder(url: url)
        let store = LogseqStore { recorder.call($0) }
        let task = Task { await store.runGraphEventsOnce(graphID: "graph", baseURL: "unused", accessToken: "test-token") }
        if mode == "cancel" || mode.hasPrefix("transport-cancel") {
            let deadline = Date().addingTimeInterval(5)
            let readyEvent = mode == "transport-cancel-connecting" ? "opened" : "frame"
            while !recorder.snapshot().contains(readyEvent), Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            precondition(recorder.snapshot().contains(readyEvent), "The transport must start before cancellation")
            if mode == "cancel" {
                task.cancel()
            } else {
                let sockets = await URLSession.shared.allTasks
                let socket = sockets.first { $0.originalRequest?.url?.absoluteString == recorder.url }
                precondition(socket != nil)
                (socket as? URLSessionWebSocketTask)?.cancel(with: .goingAway, reason: nil)
            }
        }
        _ = await task.value
        let events = recorder.snapshot()
        print("Socket \(mode): \(events), retry=\(store.graphEventsRetryDelayMilliseconds)")
        if mode == "cancel" {
            precondition(events.last == "cancelled" && store.graphEventsRetryDelayMilliseconds == 0)
            precondition(store.syncError == nil)
        } else {
            precondition(events.contains(mode == "transport-cancel-connecting" ? "opened" : "frame"))
            precondition(events.last == "failed", "A transport closure must request recovery until the owning task is cancelled")
            precondition(store.graphEventsRetryDelayMilliseconds == 1000)
        }
        print("PASS: \(mode)")
    }
}
