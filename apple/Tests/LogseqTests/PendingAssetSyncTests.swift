import Foundation
import Testing
@testable import LogseqModel

@Suite(.serialized) struct PendingAssetSyncTests {
    @Test @MainActor func authenticatedConfigurationStartsPendingSyncAfterConfigureApplies() async throws {
        let recorder = PendingSyncRequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return Self.snapshot(
                selectedGraphID: "graph-1",
                graphIDs: ["graph-1"]
            )
        }

        await store.configureAndSelectGraph(
            baseURL: "https://api-staging.logseq.io",
            token: "access-token",
            selectedGraphID: "graph-1",
            refreshGraphCatalog: true
        )

        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"beginPendingSync\"") }
        }
        let requests = recorder.all
        let configureIndex = try #require(
            requests.firstIndex { $0.contains("\"action\":\"configure\"") }
        )
        let pendingIndex = try #require(
            requests.firstIndex { $0.contains("\"action\":\"beginPendingSync\"") }
        )
        let catalogIndex = try #require(
            requests.firstIndex { $0.contains("\"action\":\"refreshGraphCatalog\"") }
        )
        #expect(configureIndex < catalogIndex)
        #expect(catalogIndex < pendingIndex)
    }

    @Test @MainActor func inaccessibleCachedGraphDoesNotStartPendingSync() async throws {
        let recorder = PendingSyncRequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"refreshGraphCatalog\"") {
                return Self.snapshot(
                    selectedGraphID: "graph-1",
                    graphIDs: ["graph-2"]
                )
            }
            return Self.snapshot(
                selectedGraphID: "graph-1",
                graphIDs: ["graph-1"]
            )
        }

        await store.configureAndSelectGraph(
            baseURL: "https://api-staging.logseq.io",
            token: "access-token",
            selectedGraphID: "graph-1",
            refreshGraphCatalog: true
        )
        try await Task.sleep(for: .milliseconds(50))

        #expect(recorder.all.contains { $0.contains("\"action\":\"refreshGraphCatalog\"") })
        #expect(!recorder.all.contains { $0.contains("\"action\":\"beginPendingSync\"") })
    }

    private static func snapshot(selectedGraphID: String, graphIDs: [String]) -> String {
        let graphs = graphIDs.map {
            "{\"id\":\"\($0)\",\"name\":\"\($0)\",\"isEncrypted\":false,\"isReady\":true}"
        }.joined(separator: ",")
        return "{\"apiVersion\":1,\"ok\":true,\"result\":{\"revision\":1,"
            + "\"query\":\"\",\"blocks\":[],\"selectedBlock\":null,"
            + "\"lastRefreshAt\":null,\"graphName\":\"\(selectedGraphID)\","
            + "\"selectedGraphId\":\"\(selectedGraphID)\",\"graphs\":[\(graphs)],"
            + "\"isSearching\":false},\"error\":null}"
    }

    @Test func pendingAssetUploadResolvesStoredPathAgainstDocumentsDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-pending-asset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assetURL = root.appendingPathComponent("Assets/photo.jpg")
        try FileManager.default.createDirectory(
            at: assetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("asset".utf8).write(to: assetURL)

        let resolved = LogseqPendingSyncFilePath.resolve(
            "Assets/photo.jpg",
            documentsDirectory: root
        )

        #expect(resolved == assetURL.standardizedFileURL)
    }

    @Test func pendingAssetUploadRejectsMissingStoredPath() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-missing-asset-\(UUID().uuidString)", isDirectory: true)

        #expect(
            LogseqPendingSyncFilePath.resolve(
                "Assets/missing.jpg",
                documentsDirectory: root
            ) == nil
        )
    }


}

private final class PendingSyncRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

@MainActor private func waitUntil(
    timeout: TimeInterval = 1.0,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}
