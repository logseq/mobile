import Foundation
import LogseqModel

private final class ImportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var importedSchema: String?
    private var importedBytes: Data?

    func record(_ request: String) throws {
        let json = try JSONSerialization.jsonObject(with: Data(request.utf8)) as! [String: Any]
        let params = json["params"] as? [String: Any] ?? [:]
        guard params["action"] as? String == "importSnapshot" else { return }
        let payload = try JSONSerialization.jsonObject(with: Data((params["payload"] as! String).utf8)) as! [String: Any]
        let metadata = try JSONSerialization.jsonObject(with: Data((payload["metadataBody"] as! String).utf8)) as! [String: Any]
        let bytes = try Data(contentsOf: URL(fileURLWithPath: payload["downloadPath"] as! String))
        lock.lock()
        defer { lock.unlock() }
        importedSchema = metadata["schema-version"] as? String
        importedBytes = bytes
    }

    func matches(schema: String?, bytes: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return importedSchema == schema && importedBytes == bytes
    }
}

@main struct SnapshotDownloadCheck {
    @MainActor static func main() async throws {
        let baseURL = CommandLine.arguments[1]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures = 0
        let cases: [(String, String?, String?)] = [
            ("catalog-schema", "65.33", "65.33"),
            ("metadata-schema", "65.32", "65.33"),
            ("missing-schema", nil, ""),
            ("blank-schema", "  ", ""),
            ("invalid-cursor", "65.33", nil),
            ("missing-row-count", "65.33", "65.33"),
            ("transport-gzip", "65.33", "65.33"),
            ("file-gzip", "65.33", "65.33"),
            ("nested-gzip", "65.33", "65.33"),
            ("unadvertised-gzip", "65.33", "65.33"),
            ("decoded-gzip", "65.33", "65.33"),
            ("corrupt-gzip", "65.33", nil),
        ]
        for (graphID, catalogSchema, expectedSchema) in cases {
            let graph: [String: Any] = [
                "id": graphID, "name": graphID, "isEncrypted": false, "isReady": true,
                "schemaVersion": catalogSchema as Any? ?? NSNull(),
            ]
            let response = String(data: try JSONSerialization.data(withJSONObject: [
                "apiVersion": 1, "ok": true,
                "result": ["revision": 1, "blocks": [], "graphs": [graph]],
            ]), encoding: .utf8)!
            let recorder = ImportRecorder()
            let store = LogseqStore { request in
                do { try recorder.record(request) } catch { fatalError("Invalid import: \(error)") }
                return response
            }
            store.applyLaunchResponse(response, actionName: "open", databasePath: directory.appendingPathComponent(graphID + ".sqlite").path)
            let succeeded = await store.bootstrapSelectedGraph(
                graphID: graphID, baseURL: baseURL, accessToken: "test-token"
            )
            var passed = succeeded == (expectedSchema != nil)
            if let expectedSchema {
                passed = passed && recorder.matches(schema: expectedSchema.isEmpty ? nil : expectedSchema, bytes: Data([0, 0, 0, 3, 65, 66, 67]))
            }
            print("\(passed ? "PASS" : "FAIL"): \(graphID), error=\(store.lastError?.message ?? "none")")
            if !passed { failures += 1 }
        }
        if failures != 0 { exit(1) }
    }
}
