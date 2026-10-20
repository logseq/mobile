import Foundation
import LogseqModel

private final class CoreHost: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffered = Data()

    init(executable: String, graphID: String) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [graphID]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
    }

    deinit {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    func call(_ request: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        input.fileHandleForWriting.write(Data((request + "\n").utf8))
        while true {
            if let end = buffered.firstIndex(of: 10) {
                let line = buffered.prefix(upTo: end)
                buffered.removeSubrange(...end)
                return String(decoding: line, as: UTF8.self)
            }
            let data = output.fileHandleForReading.availableData
            precondition(!data.isEmpty, "The shared core test host exited unexpectedly")
            buffered.append(data)
        }
    }

    func dispatch(_ action: String, _ payload: [String: Any]) {
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let request = String(data: try! JSONSerialization.data(withJSONObject: [
            "apiVersion": 1, "method": "dispatch", "params": ["action": action, "payload": encoded],
        ]), encoding: .utf8)!
        let response = try! JSONSerialization.jsonObject(with: Data(call(request).utf8)) as! [String: Any]
        precondition(response["ok"] as? Bool == true, "Shared core setup failed")
    }
}

@main struct PendingUploadRetryCheck {
    @MainActor static func main() async throws {
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: String]
        let bytes = Data((0..<(1024 * 1024)).map { UInt8($0 % 256) })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let parts = config["assetPath"]!.split(separator: "/")
        let graphID = String(parts[1])
        let assetID = String(parts[2].split(separator: ".")[0])
        func store(_ scenario: String) throws -> LogseqStore {
            let host = try CoreHost(executable: config["coreHarness"]!, graphID: graphID)
            host.dispatch("configure", ["baseUrl": config["baseURL"]! + "/" + scenario,
                "graphId": graphID, "token": config["token"]!])
            host.dispatch("addAsset", ["uuid": assetID, "title": "Retry.png", "now": 2,
                "assetType": "png", "assetSize": bytes.count, "assetChecksum": "retry-check", "localPath": file.path])
            return LogseqStore(call: { host.call($0) }, pendingTransport: { request in
                // This check exercises file transport. Graph transactions are covered by the live core gate.
                if request.filePath == nil {
                    return LogseqPendingSyncResult(status: 200, body: #"{"acceptedT":42}"#, error: nil)
                }
                return await LogseqPendingSyncHTTPTransport.send(request)
            })
        }
        for name in ["interrupted", "lost-response"] {
            let pump = try store(name)
            await pump.syncPendingForBackground()
            precondition(pump.syncError == nil, "The shared retry must recover the upload")
            var download = URLRequest(url: URL(string: config["serverURL"]! + config["assetPath"]!)!)
            download.setValue("Bearer " + config["token"]!, forHTTPHeaderField: "Authorization")
            let (actual, response) = try await URLSession.shared.data(for: download)
            precondition((response as! HTTPURLResponse).statusCode == 200 && actual == bytes,
                         "Retry must preserve the original image bytes and asset UUID")
            print("PASS: \(name) recovered through the shared core without recapturing the image")
        }
        let rejected = try store("forbidden")
        await rejected.syncPendingForBackground()
        precondition(rejected.syncError?.message.contains("HTTP 403") == true,
                     "Authentication failures must be returned without retrying")
        let exhausted = try store("unavailable")
        await exhausted.syncPendingForBackground()
        precondition(exhausted.syncError != nil && exhausted.snapshot.pendingSyncRequest == nil,
                     "Exhausted retries must stop the active pump and preserve local work")
        let cancellation = try store("cancelled")
        let cancelled = Task { await cancellation.syncPendingForBackground() }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        await cancelled.value
        precondition(cancellation.snapshot.pendingSyncRequest == nil,
                     "Cancelling the pump must stop the core retry wait")
        precondition(FileManager.default.fileExists(atPath: file.path), "Cancellation must retain the original image")
        print("PASS: permanent failures, bounded retries and cancellation use the shared core")
    }
}
