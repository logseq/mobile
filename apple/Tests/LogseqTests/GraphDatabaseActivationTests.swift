import Foundation
import Testing
@testable import LogseqModel

@Suite(.serialized) struct GraphDatabaseActivationTests {
    @Test @MainActor func reopeningCatalogForAuthenticationCannotLeaveGraphSnapshotOnCatalogRuntime() async throws {
        let recorder = GraphDatabaseRequestRecorder()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graph-activation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogURL = root.appendingPathComponent("catalog.sqlite")
        let graphDirectory = LogseqGraphLocalStorage.directoryURL(
            databasePath: catalogURL.path,
            graphID: "graph-1"
        )
        try FileManager.default.createDirectory(at: graphDirectory, withIntermediateDirectories: true)
        try Data([0]).write(to: graphDirectory.appendingPathComponent("graph.sqlite"))
        try Data([0]).write(to: graphDirectory.appendingPathComponent("sync.checkpoint"))

        let store = LogseqStore { request in
            recorder.append(request)
            let isGraph = request.contains("\"action\":\"bootstrapGraph\"")
            let result = isGraph
                ? #"{"revision":2,"blocks":[],"selectedBlock":null,"graphName":"Graph","selectedGraphId":"graph-1","appliedServerT":42,"graphBootstrap":{"kind":"ready","isEncrypted":false}}"#
                : #"{"revision":1,"blocks":[],"selectedBlock":null,"graphName":null,"selectedGraphId":null}"#
            return #"{"apiVersion":1,"ok":true,"result":\#(result),"error":null}"#
        }

        await store.openAndWait(path: catalogURL.path)
        #expect(await store.bootstrapSelectedGraph(
            graphID: "graph-1", baseURL: "http://127.0.0.1:8787", accessToken: "",
            allowSnapshotDownload: false
        ))
        store.open(path: catalogURL.path)
        #expect(await store.bootstrapSelectedGraph(
            graphID: "graph-1", baseURL: "http://127.0.0.1:8787", accessToken: "token",
            allowSnapshotDownload: false
        ))

        #expect(recorder.all.filter { $0.contains("\"action\":\"bootstrapGraph\"") }.count == 2)
    }
}

private final class GraphDatabaseRequestRecorder: @unchecked Sendable {
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
