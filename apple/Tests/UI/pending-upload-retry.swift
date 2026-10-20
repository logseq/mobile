import Foundation
import LogseqModel

@main struct PendingUploadRetryCheck {
    static func main() async throws {
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: String]
        let bytes = Data((0..<(1024 * 1024)).map { UInt8($0 % 256) })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for name in ["interrupted", "lost-response"] {
            let url = config["baseURL"]! + "/" + name + config["assetPath"]!
            let request = LogseqPendingSyncRequest(id: 1, method: "PUT", url: url, body: nil,
                token: config["token"]!, filePath: file.path, contentType: "image/png",
                headers: ["x-amz-meta-checksum":"retry-check", "x-amz-meta-type":"png"])
            let result = await LogseqPendingSyncHTTPTransport.send(request)
            guard result.status == 200 else {
                print("FAIL: \(name): \(result.error ?? result.body ?? "missing response")")
                exit(1)
            }
            var download = URLRequest(url: URL(string: config["serverURL"]! + config["assetPath"]!)!)
            download.setValue("Bearer " + config["token"]!, forHTTPHeaderField: "Authorization")
            let (actual, response) = try await URLSession.shared.data(for: download)
            precondition((response as! HTTPURLResponse).statusCode == 200 && actual == bytes,
                         "Retry must preserve the original image bytes and asset UUID")
            print("PASS: \(name) recovered without recapturing the image")
        }
        func request(_ name: String) -> LogseqPendingSyncRequest {
            LogseqPendingSyncRequest(id: 2, method: "PUT", url: config["baseURL"]! + "/" + name + config["assetPath"]!,
                body: nil, token: config["token"]!, filePath: file.path, contentType: "image/png")
        }
        let rejected = await LogseqPendingSyncHTTPTransport.send(request("forbidden"))
        precondition(rejected.status == 403, "Authentication failures must be returned without retrying")
        let exhausted = await LogseqPendingSyncHTTPTransport.send(request("unavailable"))
        precondition(exhausted.status == nil && exhausted.error != nil, "Persistent failures must remain retryable local work")
        let cancelled = Task { await LogseqPendingSyncHTTPTransport.send(request("cancelled")) }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        precondition(cancelledResult.status == nil && cancelledResult.error != nil,
                     "Cancelling the pump must stop transport retries")
        print("PASS: permanent failures, bounded retries and cancellation")
    }
}
