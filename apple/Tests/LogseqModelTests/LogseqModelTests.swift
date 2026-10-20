import Testing
import Foundation
@testable import LogseqModel

private let testEmptySnapshotJSON = """
{
  "apiVersion": 1,
  "ok": true,
  "result": {
    "revision": 1,
    "blocks": [],
    "selectedBlock": null,
    "lastRefreshAt": null,
    "graphName": null
  },
  "error": null
}
"""

@Suite(.serialized) struct LogseqModelTests {

    @Test func logseqModel() throws {
        #expect(1 + 2 == 3, "basic test")
    }

    @Test @MainActor func appliedCoreResponsesAreRelayedToTheLGHost() {
        var relayed: [String] = []
        let store = LogseqStore(
            call: { _ in "" },
            responseObserver: { relayed.append($0) }
        )

        store.applyLaunchResponse(
            testEmptySnapshotJSON,
            actionName: "open",
            databasePath: "/tmp/logseq-test.sqlite"
        )

        #expect(relayed == [testEmptySnapshotJSON])
    }

    @Test func decodeType() throws {
        // load the TestData.json file from the Resources folder and decode it into a struct
        let resourceURL: URL = try #require(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        #expect(testData.testModuleName == "LogseqModel")
    }

    @Test func failedSyncStatusIsSeparateFromPending() throws {
        let failedBlock = LogseqBlock(
            uuid: "failed",
            title: "Failed",
            pageId: "journal/2026-08-13",
            parentId: nil,
            createdAt: 1_776_000_000_000,
            updatedAt: 1_776_000_000_000,
            syncStatus: "failed"
        )
        let pendingBlock = LogseqBlock(
            uuid: "pending",
            title: "Pending",
            pageId: "journal/2026-08-13",
            parentId: nil,
            createdAt: 1_776_000_000_001,
            updatedAt: 1_776_000_000_001,
            syncStatus: "pending"
        )

        #expect(failedBlock.isFailedSync)
        #expect(!failedBlock.isPendingSync)
        #expect(!pendingBlock.isFailedSync)
        #expect(pendingBlock.isPendingSync)
    }

    @Test func modelIdentityAndTimestampPresentationAreStable() {
        let entity = LogseqEntitySummary(uuid: "entity-1", title: "Page")
        let status = LogseqTaskStatus(
            uuid: "status-1",
            ident: "user.status/waiting",
            title: "Waiting",
            icon: nil
        )
        let block = LogseqBlock(
            uuid: "block-1",
            title: "Block",
            pageId: "page-1",
            parentId: nil,
            createdAt: 1_776_000_000_000,
            updatedAt: 1_776_000_000_000,
            syncStatus: nil
        )
        let row = LogseqOutlineRow(
            block: block,
            depth: 0,
            hasChildren: false,
            isCollapsed: false
        )
        let page = LogseqSidebarPage(uuid: "page-1", title: "Page")
        let candidate = LogseqOutlinerAutocompleteCandidate(label: "Page", value: "page-1")
        let projection = LogseqNodeProjection(
            uuid: "node-1",
            isTag: false,
            isProperty: false,
            page: page,
            blocks: [block],
            relatedBlocks: [],
            linkedReferenceBlocks: [],
            outlinerState: LogseqOutlinerState.empty,
            outlinerRows: [row],
            outlinerAutocompleteCandidates: []
        )

        #expect(entity.id == entity.uuid)
        #expect(status.id == status.uuid)
        #expect(block.id == block.uuid)
        #expect(block.createdDate.timeIntervalSince1970 == 1_776_000_000)
        #expect(!block.dayTitle.isEmpty)
        #expect(block.journalSectionID == block.dayTitle)
        #expect(!block.timeTitle.isEmpty)
        #expect(row.id == block.uuid)
        #expect(page.id == page.uuid)
        #expect(candidate.id == "Page|page-1")
        #expect(projection.id == projection.uuid)
    }

    @Test func outlinerAutocompleteUsesTheUnifiedNodeKind() throws {
        let autocomplete = try JSONDecoder().decode(
            LogseqOutlinerAutocomplete.self,
            from: Data(#"{"kind":"node","query":"Project"}"#.utf8)
        )
        #expect(autocomplete.kind == LogseqOutlinerAutocompleteKind.node)
        #expect(autocomplete.query == "Project")
    }

    @Test func decodesTypedMldocRenderNodesWithoutParsingInSwift() throws {
        let data = Data(#"{"uuid":"source","title":"See [[target]]","pageId":"page","createdAt":1,"updatedAt":1,"markup":[{"type":"text","text":"See "},{"type":"nodeReference","uuid":"target","title":"Target","children":[]}]}"#.utf8)
        let block = try JSONDecoder().decode(LogseqBlock.self, from: data)

        #expect(block.markup.map(\.type) == [
            LogseqMarkupNodeType.text, LogseqMarkupNodeType.nodeReference,
        ])
        #expect(block.markup[0].text == "See ")
        #expect(block.markup[1].uuid == "target")
        #expect(block.markup[1].title == "Target")
    }

    @Test func decodesTaskTagsReferencesAndAssetMetadata() throws {
        let data = Data(##"{"uuid":"asset-1","title":"photo.jpg","pageId":"journal-1","createdAt":1,"updatedAt":2,"tags":[{"uuid":"tag-1","title":"Project"}],"references":[{"uuid":"page-1","title":"Project"}],"status":{"uuid":"status-1","ident":"user.status/waiting","title":"Waiting","icon":{"type":"tabler-icon","id":"clock","color":"#7c3aed"}},"isAsset":true,"assetType":"jpg","assetSize":2048,"assetChecksum":"abc","localPath":"/documents/photo.jpg"}"##.utf8)
        let block = try JSONDecoder().decode(LogseqBlock.self, from: data)
        #expect(block.tags.first?.title == "Project")
        #expect(block.references.first?.title == "Project")
        #expect(block.status?.icon?.id == "clock")
        #expect(block.status?.icon?.color == "#7c3aed")
        #expect(block.isAsset)
        #expect(block.assetType == "jpg")
        #expect(block.assetSize == 2048)
        #expect(block.localPath == "/documents/photo.jpg")
    }

    @Test func pendingAssetUploadDecodesRawPUTHeaders() throws {
        let data = Data(#"{"revision":1,"blocks":[],"selectedBlock":null,"lastRefreshAt":null,"pendingSyncRequest":{"id":7,"method":"PUT","url":"https://sync.example/assets/graph/asset.png","body":null,"token":"token","filePath":"Assets/asset.png","contentType":"image/png","headers":{"x-amz-meta-checksum":"abc123","x-amz-meta-type":"png"}}}"#.utf8)
        let snapshot = try JSONDecoder().decode(LogseqSnapshot.self, from: data)
        let request = try #require(snapshot.pendingSyncRequest)

        #expect(request.method == "PUT")
        #expect(request.headers["x-amz-meta-checksum"] == "abc123")
        #expect(request.headers["x-amz-meta-type"] == "png")
    }

    @Test func snapshotDecodesCustomTaskStatusCatalog() throws {
        let data = Data(##"{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Test","isSearching":false,"taskStatuses":[{"uuid":"status-1","ident":"user.status/waiting","title":"Waiting","icon":{"type":"tabler-icon","id":"clock","color":"#7c3aed"}}]}"##.utf8)
        let snapshot = try JSONDecoder().decode(LogseqSnapshot.self, from: data)
        #expect(snapshot.taskStatuses?.first?.title == "Waiting")
        #expect(snapshot.taskStatuses?.first?.icon?.color == "#7c3aed")
    }

    @Test func snapshotPreservesGraphEncryptionAndReadiness() throws {
        let data = Data(#"{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":null,"selectedGraphId":null,"graphs":[{"id":"plain-1","name":"Plain","isEncrypted":false,"isReady":true},{"id":"encrypted-1","name":"Encrypted","isEncrypted":true,"isReady":true}],"isSearching":false}"#.utf8)
        let snapshot = try JSONDecoder().decode(LogseqSnapshot.self, from: data)
        #expect(snapshot.graphs?.map(\.id) == ["plain-1", "encrypted-1"])
        #expect(snapshot.graphs?.first?.isEncrypted == false)
        #expect(snapshot.graphs?.last?.isEncrypted == true)
        #expect(snapshot.graphs?.allSatisfy(\.isReady) == true)
    }

    @Test func snapshotPreservesSidebarFavoritesAndRecentPages() throws {
        let data = Data(#"{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Test","isSearching":false,"favorites":[{"uuid":"favorite-1","title":"Favorite page"}],"recentPages":[{"uuid":"recent-1","title":"Recent page"}]}"#.utf8)
        let snapshot = try JSONDecoder().decode(LogseqSnapshot.self, from: data)
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let favorites = try #require(object["favorites"] as? [[String: Any]])
        let recentPages = try #require(object["recentPages"] as? [[String: Any]])

        #expect(favorites.first?["uuid"] as? String == "favorite-1")
        #expect(favorites.first?["title"] as? String == "Favorite page")
        #expect(recentPages.first?["uuid"] as? String == "recent-1")
        #expect(recentPages.first?["title"] as? String == "Recent page")
    }

    @Test func snapshotDefaultsMissingSidebarCollectionsToEmpty() throws {
        let data = Data(#"{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":null,"isSearching":false}"#.utf8)
        let snapshot = try JSONDecoder().decode(LogseqSnapshot.self, from: data)
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect((object["favorites"] as? [Any])?.isEmpty == true)
        #expect((object["recentPages"] as? [Any])?.isEmpty == true)
    }

    @Test func snapshotDecodesDueFlashcards() throws {
        let data = Data(#"{"revision":1,"blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Test","flashcards":[{"block":{"uuid":"card-1","title":"Question {{cloze answer}}","pageId":"page","createdAt":1,"updatedAt":1,"syncStatus":"synced","isAsset":false},"children":[{"uuid":"answer-1","title":"Child answer","pageId":"page","parentId":"card-1","createdAt":1,"updatedAt":1,"syncStatus":"synced","isAsset":false}],"due":1776000000000,"repetitions":3,"lapses":1,"state":"review"}]}"#.utf8)
        let snapshot = try JSONDecoder().decode(LogseqSnapshot.self, from: data)

        #expect(snapshot.flashcards.count == 1)
        #expect(snapshot.flashcards.first?.block.uuid == "card-1")
        #expect(snapshot.flashcards.first?.due == 1_776_000_000_000)
        #expect(snapshot.flashcards.first?.repetitions == 3)
        #expect(snapshot.flashcards.first?.lapses == 1)
        #expect(snapshot.flashcards.first?.state == "review")
        #expect(snapshot.flashcards.first?.children.first?.title == "Child answer")
    }

    @Test @MainActor func resettingToCatalogReopensTheConfiguredDatabase() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return testEmptySnapshotJSON
        }
        store.open(path: "/tmp/catalog.sqlite")
        try await waitUntil { recorder.all.count == 1 }

        await store.resetToCatalog()

        #expect(recorder.all.count == 2)
        #expect(recorder.all.last?.contains("\"method\":\"open\"") == true)
        #expect(recorder.all.last?.contains("catalog.sqlite") == true)
    }

    @Test @MainActor func resettingBeforeOpeningReportsAnError() async {
        let store = LogseqStore { _ in testEmptySnapshotJSON }

        await store.resetToCatalog()

        #expect(store.lastError?.code == "database_not_open")
    }

    @Test func gzipSnapshotIsDecodedBeforeNativeImport() throws {
        let compressed = try #require(Data(base64Encoded: "H4sIAAAAAAAC/2NgYGB2dHIGAMqqG9MHAAAA"))
        let compressedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-snapshot-\(UUID().uuidString).gz")
        try compressed.write(to: compressedURL)
        defer { try? FileManager.default.removeItem(at: compressedURL) }

        let decodedURL = try LogseqGraphSyncHTTP.decodeSnapshotFile(
            at: compressedURL,
            contentEncoding: "gzip"
        )
        defer {
            if decodedURL != compressedURL {
                try? FileManager.default.removeItem(at: decodedURL)
            }
        }

        #expect(try Data(contentsOf: decodedURL) == Data([0, 0, 0, 3, 65, 66, 67]))
    }

    @Test func webSocketConnectionFailuresHaveUsefulUserFacingMessages() {
        #expect(LogseqGraphWebSocketFailurePolicy.userFacingMessage(URLError(.timedOut))
            == "The sync server timed out. Check that it is running and reachable, then try again.")
        #expect(LogseqGraphWebSocketFailurePolicy.userFacingMessage(URLError(.notConnectedToInternet))
            == "No network connection. Sync will resume automatically when the network is available.")
        #expect(LogseqGraphWebSocketFailurePolicy.userFacingMessage(URLError(.cannotConnectToHost))
            == "The sync server is unreachable. Check that it is running and reachable.")
        #expect(LogseqGraphWebSocketFailurePolicy.userFacingMessage(URLError(.unsupportedURL))
            == "The sync server address is invalid.")
    }

    @Test @MainActor func graphDiscoveryRunsWhenThereIsNoCachedSelection() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            let result: String
            if request.contains("\"action\":\"refresh\"") {
                result = #"{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":null,"selectedGraphId":null,"graphs":[{"id":"plain-1","name":"Sync 2","isEncrypted":false,"isReady":true}],"isSearching":false}"#
            } else if request.contains("\"action\":\"selectGraph\"") {
                result = #"{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Sync 2","selectedGraphId":"plain-1","graphs":[{"id":"plain-1","name":"Sync 2","isEncrypted":false,"isReady":true}],"isSearching":false}"#
            } else {
                result = #"{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":null,"selectedGraphId":null,"graphs":[],"isSearching":false}"#
            }
            return #"{"apiVersion":1,"ok":true,"result":\#(result),"error":null}"#
        }

        await store.configureAndSelectGraph(
            baseURL: "http://127.0.0.1:8787",
            token: "oauth-token",
            selectedGraphID: nil
        )

        #expect(recorder.all.count == 2)
        #expect(recorder.all[0].contains("\"action\":\"configure\""))
        #expect(recorder.all[0].contains("\\\"graphId\\\":\\\"\\\""))
        #expect(recorder.all[1].contains("\"action\":\"refresh\""))
        #expect(store.snapshot.graphs?.first?.name == "Sync 2")
    }

    @Test @MainActor func selectedGraphRefreshesThePersistedCatalogWhenOnline() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"configure\"") {
                return #"{"apiVersion":1,"ok":true,"result":{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Sync 2","selectedGraphId":"plain-1","graphs":[{"id":"plain-1","name":"Sync 2","isEncrypted":false,"isReady":true}],"isSearching":false},"error":null}"#
            }
            if request.contains("\"action\":\"refreshGraphCatalog\"") {
                return #"{"apiVersion":1,"ok":true,"result":{"revision":2,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Sync 2","selectedGraphId":"plain-1","graphs":[{"id":"plain-1","name":"Sync 2","isEncrypted":false,"isReady":true}],"isSearching":false},"error":null}"#
            }
            return #"{"apiVersion":1,"ok":false,"result":null,"error":{"code":"offline","message":"Network unavailable"}}"#
        }

        await store.configureAndSelectGraph(
            baseURL: "http://192.168.10.116:8787",
            token: "cached-token",
            selectedGraphID: "plain-1",
            refreshGraphCatalog: true
        )

        #expect(recorder.all.count == 2)
        #expect(recorder.all[0].contains("\\\"graphId\\\":\\\"plain-1\\\""))
        #expect(recorder.all[1].contains("\"action\":\"refreshGraphCatalog\""))
        #expect(store.snapshot.selectedGraphId == "plain-1")
        #expect(store.snapshot.graphName == "Sync 2")
        #expect(store.lastError == nil)
    }

    @Test @MainActor func selectedGraphColdStartDoesNotBlockCoreOnCatalogRefresh() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return #"{"apiVersion":1,"ok":true,"result":{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Sync 2","selectedGraphId":"plain-1","graphs":[{"id":"plain-1","name":"Sync 2","isEncrypted":false,"isReady":true}],"isSearching":false},"error":null}"#
        }

        await store.configureAndSelectGraph(
            baseURL: "http://192.168.10.116:8787",
            token: "cached-token",
            selectedGraphID: "plain-1"
        )

        #expect(recorder.all.count == 1)
        #expect(recorder.all[0].contains("\"action\":\"configure\""))
        #expect(!recorder.all[0].contains("refreshGraphCatalog"))
    }

    @Test @MainActor func graphBootstrapExecutesTheSharedStorageDecision() async throws {
        let recorder = RequestRecorder()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logseq-startup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("logseq.sqlite")
        let graphDirectory = LogseqGraphLocalStorage.directoryURL(
            databasePath: databaseURL.path,
            graphID: "plain-1"
        )
        try FileManager.default.createDirectory(
            at: graphDirectory,
            withIntermediateDirectories: true
        )
        try Data([0]).write(to: graphDirectory.appendingPathComponent("graph.sqlite"))
        try Data([0]).write(to: graphDirectory.appendingPathComponent("sync.checkpoint"))

        let store = LogseqStore { request in
            recorder.append(request)
            let result: String
            if request.contains("\"action\":\"bootstrapGraph\"") {
                result = #"{"revision":2,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Sync 2","selectedGraphId":"plain-1","graphs":[{"id":"plain-1","name":"Sync 2","isEncrypted":false,"isReady":true}],"appliedServerT":42,"isSearching":false,"graphBootstrap":{"kind":"ready","isEncrypted":false}}"#
            } else {
                result = #"{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":null,"selectedGraphId":null,"graphs":[],"isSearching":false}"#
            }
            return #"{"apiVersion":1,"ok":true,"result":\#(result),"error":null}"#
        }
        store.open(path: databaseURL.path)
        try await waitUntil { recorder.all.count == 1 }

        let restored = await store.bootstrapSelectedGraph(
            graphID: "plain-1",
            baseURL: "http://127.0.0.1:8787",
            accessToken: "",
            allowSnapshotDownload: false
        )
        let authenticated = await store.bootstrapSelectedGraph(
            graphID: "plain-1",
            baseURL: "http://127.0.0.1:8787",
            accessToken: "authenticated-token"
        )
        #expect(restored)
        #expect(authenticated)

        let openGraphRequests = recorder.all.filter {
            $0.contains("\"action\":\"bootstrapGraph\"")
        }
        #expect(openGraphRequests.count == 2)
    }

    @Test @MainActor func cachedGraphRestoresWithoutNetworkWhenOffline() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return #"{"apiVersion":1,"ok":true,"result":{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Sync 2","selectedGraphId":"plain-1","graphs":[{"id":"plain-1","name":"Sync 2","isEncrypted":false,"isReady":true}],"isSearching":false},"error":null}"#
        }

        await store.configureAndSelectGraph(
            baseURL: "http://192.168.10.116:8787",
            token: "",
            selectedGraphID: "plain-1"
        )

        #expect(recorder.all.count == 1)
        #expect(recorder.all[0].contains("\"action\":\"configure\""))
        #expect(store.snapshot.graphName == "Sync 2")
    }

    @Test @MainActor func configurePayloadIsValidJSONForEveryTokenCharacter() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return testEmptySnapshotJSON
        }
        let token = "token\u{0001}\"\\suffix"

        store.configure(
            baseURL: "http://127.0.0.1:8787",
            token: token,
            graphID: "plain-1",
            refreshAfterApply: false
        )
        try await waitUntil { recorder.all.count == 1 }

        let outer = try? JSONSerialization.jsonObject(
            with: Data(recorder.all[0].utf8)
        ) as? [String: Any]
        let params = outer?["params"] as? [String: Any]
        let payload = params?["payload"] as? String
        let decodedPayload = payload.flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        #expect(decodedPayload?["token"] as? String == token)
    }

    @Test @MainActor func configureDoesNotBlockTheMainActorWhenCoreIsSlow() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"configure\"") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [],
                "selectedBlock": null,
                "lastRefreshAt": null,
                "graphName": "pat test",
                "isSearching": false
              },
              "error": null
            }
            """
        }

        let start = Date()
        store.configure(baseURL: "https://api-staging.logseq.io", token: "token")
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.1)
        try await waitUntil {
            recorder.first?.contains("\"action\":\"configure\"") == true
                && store.snapshot.graphName == "pat test"
        }
    }

    @Test @MainActor func configureNormalizesStagingBaseURLAndToken() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [],
                "selectedBlock": null,
                "lastRefreshAt": null,
                "graphName": null,
                "isSearching": false
              },
              "error": null
            }
            """
        }

        store.configure(baseURL: " https://staging-api.logseq.io ", token: " token-value ")

        try await waitUntil {
            recorder.first?.contains("\"action\":\"configure\"") == true
        }

        let request = try #require(recorder.first)
        #expect(request.contains("api-staging.logseq.io"))
        #expect(!request.contains("staging-api.logseq.io"))
        #expect(request.contains("token-value"))
    }

    @Test @MainActor func configureRefreshesAfterConnectionApplies() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [
                  {
                    "uuid": "remote-1",
                    "title": "Remote block",
                    "pageId": "page-1",
                    "createdAt": 1776000000000,
                    "updatedAt": 1776000000000,
                    "syncStatus": "synced"
                  }
                ],
                "selectedBlock": null,
                "lastRefreshAt": 1776000000000,
                "graphName": "pat test",
                "isSearching": false
              },
              "error": null
            }
            """
        }

        store.configure(baseURL: "https://api-staging.logseq.io", token: "token")

        try await waitUntil {
            let requests = recorder.all
            return requests.contains { $0.contains("\"action\":\"configure\"") }
                && requests.contains { $0.contains("\"action\":\"refresh\"") }
                && requests.contains { $0.contains("\"action\":\"beginPendingSync\"") }
        }

        #expect(store.snapshot.graphName == "pat test")
        #expect(store.snapshot.blocks.first?.title == "Remote block")
    }

    @Test @MainActor func sharedCapturePublishesCoreResultBeforeSyncing() async throws {
        let recorder = RequestRecorder()
        let request = LogseqPendingSyncRequest(
            id: 1,
            method: "POST",
            url: "https://api.example/capture",
            body: "{}",
            token: "access-token",
            filePath: nil,
            contentType: "application/json"
        )
        let store = LogseqStore(
            call: { call in
                recorder.append(call)
                if call.contains("\"action\":\"beginPendingSync\"") {
                    return pendingPumpSnapshot(query: "", syncStatus: "pending", request: request)
                }
                if call.contains("\"action\":\"completePendingSync\"") {
                    return pendingPumpSnapshot(query: "", syncStatus: "submitted", request: nil)
                }
                return pendingPumpSnapshot(query: "", syncStatus: "pending", request: nil)
            },
            pendingTransport: { _ in
                LogseqPendingSyncResult(status: 201, body: #"{"uuid":"local-1"}"#, error: nil)
            }
        )

        capture(store, "Offline capture")

        try await waitUntil {
            recorder.first?.contains("\"action\":\"captureShared\"") == true
        }

        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"completePendingSync\"") }
                && store.snapshot.blocks.first?.isPendingSync == false
        }

        let requests = recorder.all
        #expect(requests.contains { $0.contains("\"action\":\"beginPendingSync\"") })
        #expect(requests.contains { $0.contains("\"action\":\"completePendingSync\"") })
        #expect(store.snapshot.blocks.first?.isPendingSync == false)
    }

    @Test @MainActor func pendingSyncUsesTheCoreOwnedGraphProjection() async throws {
        let recorder = RequestRecorder()
        let request = LogseqPendingSyncRequest(
            id: 1, method: "POST", url: "https://api.example/capture", body: "{}", token: "access-token",
            filePath: nil, contentType: "application/json"
        )
        let beginSnapshot = pendingPumpSnapshot(query: "", syncStatus: "pending", request: request)
        let completeSnapshot = pendingPumpSnapshot(query: "", syncStatus: "submitted", request: nil)
            .replacingOccurrences(of: "\"revision\": 1", with: "\"revision\": 1, \"appliedServerT\": 43")
        let store = LogseqStore(
            call: { call in
                recorder.append(call)
                if call.contains("\"action\":\"beginPendingSync\"") {
                    return beginSnapshot
                }
                if call.contains("\"action\":\"completePendingSync\"") {
                    return completeSnapshot
                }
                return pendingPumpSnapshot(query: "", syncStatus: "pending", request: nil)
            },
            pendingTransport: { _ in
                LogseqPendingSyncResult(status: 201, body: #"{"uuid":"local-1"}"#, error: nil)
            }
        )

        capture(store, "Offline capture")

        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"completePendingSync\"") }
        }
        #expect(store.snapshot.blocks.first?.title == "Offline capture")
        #expect(store.snapshot.appliedServerT == 43)
    }

    @Test @MainActor func sharedCaptureDoesNotBlockTheMainActorWhenCoreIsSlow() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"captureShared\"") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [
                  {
                    "uuid": "local-1",
                    "title": "Slow local capture",
                    "pageId": "journal/2026-08-13",
                    "createdAt": 1776000000000,
                    "updatedAt": 1776000000000,
                    "syncStatus": "pending"
                  }
                ],
                "selectedBlock": null,
                "lastRefreshAt": 1776000000000,
                "isSearching": false
              },
              "error": null
            }
            """
        }

        let start = Date()
        capture(store, "Slow local capture")
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.1)
        #expect(store.snapshot.blocks.isEmpty)
        try await waitUntil {
            recorder.first?.contains("\"action\":\"captureShared\"") == true
                && store.snapshot.blocks.first?.title == "Slow local capture"
        }
        #expect(store.snapshot.blocks.first?.isPendingSync == true)
    }

    @Test @MainActor func pendingHTTPDoesNotBlockNavigationOrLocalBlockCreation() async throws {
        let recorder = RequestRecorder()
        let transport = SuspendedPendingTransport()
        let store = LogseqStore(
            call: { request in
                recorder.append(request)
                if request.contains("\"action\":\"beginPendingSync\"") {
                    if recorder.all.contains(where: { $0.contains("completePendingSync") }) {
                        return pendingPumpSnapshot(query: "local", syncStatus: "submitted", request: nil)
                    }
                    return pendingPumpSnapshot(
                        query: "",
                        syncStatus: "pending",
                        request: LogseqPendingSyncRequest(
                            id: 1,
                            method: "POST",
                            url: "https://api.example/api/v1/graphs/graph-1/capture",
                            body: #"{"blocks":[{"uuid":"local-1","title":"Offline capture"}]}"#,
                            token: "access-token",
                            filePath: nil,
                            contentType: "application/json"
                        )
                    )
                }
                if request.contains("\"action\":\"completePendingSync\"") {
                    return pendingPumpSnapshot(query: "local", syncStatus: "submitted", request: nil)
                }
                if request.contains("\"action\":\"selectGraph\"") {
                    return pendingPumpSnapshot(query: "local", syncStatus: "pending", request: nil)
                }
                return pendingPumpSnapshot(query: "", syncStatus: "pending", request: nil)
            },
            pendingTransport: { request in
                await transport.send(request)
            }
        )

        capture(store, "Offline capture")
        try await waitUntilAsync { await transport.hasStarted }

        Task { _ = await store.selectGraphAndWait("page-1") }
        capture(store, "Offline child")
        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"selectGraph\"") }
                && recorder.all.filter { $0.contains("\"action\":\"captureShared\"") }.count == 2
        }
        #expect(await transport.isWaiting)

        await transport.resume()
        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"completePendingSync\"") }
                && store.snapshot.blocks.first?.syncStatus == "submitted"
        }
    }

    @Test @MainActor func networkSyncFailureDoesNotBecomeALocalOperationError() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("beginSyncTransport") {
                return #"{"apiVersion":1,"ok":false,"error":{"code":"invalid_sync_transport","message":"The sync server address is invalid."}}"#
            }
            return outlineSnapshotJSON(blocks: [], appliedServerT: 51)
        }
        store.refreshSoon()
        try await waitUntil { store.snapshot.appliedServerT == 51 }

        _ = await store.runGraphEventsOnce(
            graphID: "graph-1",
            baseURL: "://",
            accessToken: "access-token"
        )

        #expect(store.lastError == nil)
        #expect(store.syncError?.code == "invalid_sync_transport")
        #expect(store.syncError?.message == "The sync server address is invalid.")
        Task { _ = await store.selectGraphAndWait("page-1") }
        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"selectGraph\"") }
        }
    }

    @Test @MainActor func rejectedTransactionStopsThePumpAndKeepsItsReason() async throws {
        let recorder = RequestRecorder()
        let request = LogseqPendingSyncRequest(
            id: 1,
            method: "POST",
            url: "https://api.example/sync/graph-1/tx/batch",
            body: "{}",
            token: "access-token",
            filePath: nil,
            contentType: "application/json"
        )
        let store = LogseqStore(
            call: { call in
                recorder.append(call)
                let completed = call.contains("completePendingSync")
                return pendingPumpSnapshot(query: "", syncStatus: "pending", request: completed ? nil : request,
                    error: completed ? "Sync server rejected the change: db transact failed" : nil)
            },
            pendingTransport: { _ in
                LogseqPendingSyncResult(
                    status: 200,
                    body: #"{"type":"tx/reject","reason":"db transact failed","error-detail":"DB write failed with invalid data"}"#,
                    error: nil
                )
            }
        )

        store.syncPending()
        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"completePendingSync\"") }
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(
            recorder.all.filter { $0.contains("\"action\":\"completePendingSync\"") }.count == 1
        )
        #expect(store.syncError?.message.contains("db transact failed") == true)
    }

    @Test @MainActor func cancelingBackgroundPendingSyncCancelsTheHTTPTransport() async throws {
        let recorder = RequestRecorder()
        let transport = SuspendedPendingTransport()
        let store = LogseqStore(
            call: { request in
                recorder.append(request)
                if request.contains("\"action\":\"beginPendingSync\"") {
                    return pendingPumpSnapshot(
                        query: "",
                        syncStatus: "pending",
                        request: LogseqPendingSyncRequest(
                            id: 1,
                            method: "POST",
                            url: "https://api.example/capture",
                            body: "{}",
                            token: "access-token",
                            filePath: nil,
                            contentType: "application/json"
                        )
                    )
                }
                return pendingPumpSnapshot(query: "", syncStatus: "pending", request: nil)
            },
            pendingTransport: { request in
                await transport.send(request)
            }
        )

        let background = Task { await store.syncPendingForBackground() }
        try await waitUntilAsync { await transport.hasStarted }

        background.cancel()
        await background.value

        #expect(await transport.wasCancelled)
        #expect(recorder.all.contains { $0.contains("\"action\":\"cancelPendingSync\"") })
        #expect(!recorder.all.contains { $0.contains("\"action\":\"completePendingSync\"") })
    }

    @Test @MainActor func sharedCapturePublishesOnlyAfterTheLocalWriteIsDurable() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"captureShared\"") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            let uuid = latestCaptureUUID(in: recorder) ?? "local-durable"
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [
                  {
                    "uuid": "\(uuid)",
                    "title": "Durable capture",
                    "pageId": "journal/2026-08-13",
                    "createdAt": 1776000000000,
                    "updatedAt": 1776000000000,
                    "syncStatus": "pending"
                  }
                ],
                "selectedBlock": null,
                "lastRefreshAt": 1776000000000,
                "isSearching": false
              },
              "error": null
            }
            """
        }

        let start = Date()
        capture(store, "Durable capture")

        #expect(Date().timeIntervalSince(start) < 0.1)
        #expect(store.snapshot.blocks.isEmpty)
        try await waitUntil {
            store.snapshot.blocks.first?.title == "Durable capture"
                && store.snapshot.blocks.first?.isPendingSync == true
        }
    }

    @Test @MainActor func backgroundSyncOnlySubmitsPendingWrites() async throws {
        let recorder = RequestRecorder()
        let pendingRequest = LogseqPendingSyncRequest(
            id: 1,
            method: "POST",
            url: "https://api.example/capture",
            body: "{}",
            token: "access-token",
            filePath: nil,
            contentType: "application/json"
        )
        let store = LogseqStore(
            call: { request in
                recorder.append(request)
                if request.contains("\"action\":\"beginPendingSync\"") {
                    return pendingPumpSnapshot(query: "", syncStatus: "pending", request: pendingRequest)
                }
                return pendingPumpSnapshot(query: "", syncStatus: "submitted", request: nil)
            },
            pendingTransport: { _ in
                try? await Task.sleep(nanoseconds: 150_000_000)
                return LogseqPendingSyncResult(status: 201, body: #"{"uuid":"local-1"}"#, error: nil)
            }
        )

        let start = Date()
        await store.syncPendingForBackground()
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed >= 0.15)
        #expect(!recorder.all.contains { $0.contains("\"action\":\"refresh\"") })
        #expect(recorder.all.contains { $0.contains("\"action\":\"beginPendingSync\"") })
        #expect(recorder.all.contains { $0.contains("\"action\":\"completePendingSync\"") })
        #expect(store.snapshot.blocks.first?.syncStatus == "submitted")
    }

    @Test @MainActor func backgroundConfigurationUsesTheCachedGraphCatalog() async {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return testEmptySnapshotJSON
        }

        await store.configureAndSelectGraph(
            baseURL: "http://127.0.0.1:8787",
            token: "access-token",
            selectedGraphID: "graph-1",
            refreshGraphCatalog: false
        )

        #expect(recorder.all.contains { $0.contains("\"action\":\"configure\"") })
        #expect(!recorder.all.contains { $0.contains("\"action\":\"refreshGraphCatalog\"") })
        #expect(!recorder.all.contains { $0.contains("\"action\":\"refresh\"") })
    }

    @Test @MainActor func concurrentRefreshCallsAreCoalesced() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"refresh\"") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            return testEmptySnapshotJSON
        }

        store.refreshSoon()
        store.refreshSoon()

        try await waitUntil(timeout: 1.0) {
            recorder.all.contains { $0.contains("\"action\":\"refresh\"") }
                && store.isRefreshing == false
        }

        let refreshCount = recorder.all.filter { $0.contains("\"action\":\"refresh\"") }.count
        #expect(refreshCount == 1)
    }

    @Test @MainActor func nativeCoreCallsAreSerializedAcrossAsyncAndImmediateActions() async throws {
        let probe = CoreCallConcurrencyProbe()
        let store = LogseqStore { request in
            probe.call(request, delayingAction: "configure")
        }

        store.configure(
            baseURL: "https://api-staging.logseq.io",
            token: "token",
            refreshAfterApply: false
        )
        try await waitUntil {
            probe.events.contains("start configure")
        }

        let start = Date()
        store.open(path: "/tmp/serialized-core.sqlite")
        Task { _ = await store.selectGraphAndWait("queued") }
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.1)
        try await waitUntil(timeout: 2.0) {
            probe.events.contains("finish selectGraph")
        }
        #expect(probe.maximumConcurrentCalls == 1)
        #expect(probe.events == [
            "start configure",
            "finish configure",
            "start selectGraph",
            "finish selectGraph",
            "start open",
            "finish open",
        ])
    }

    @Test @MainActor func interactiveNavigationJumpsAheadOfQueuedMaintenance() async throws {
        let probe = CoreCallConcurrencyProbe()
        let store = LogseqStore { request in
            probe.call(request, delayingAction: "configure")
        }

        store.configure(
            baseURL: "https://api-staging.logseq.io/first",
            token: "token",
            refreshAfterApply: false
        )
        try await waitUntil { probe.events.contains("start configure") }
        store.configure(
            baseURL: "https://api-staging.logseq.io/second",
            token: "token",
            refreshAfterApply: false
        )
        Task { _ = await store.selectGraphAndWait("page-1") }

        try await waitUntil(timeout: 2.0) {
            probe.events.contains("finish selectGraph")
                && probe.events.filter { $0 == "finish configure" }.count == 2
        }
        #expect(probe.maximumConcurrentCalls == 1)
        #expect(probe.events == [
            "start configure",
            "finish configure",
            "start selectGraph",
            "finish selectGraph",
            "start configure",
            "finish configure",
        ])
    }

    @Test @MainActor func nativeCoreSerializationContinuesAfterAnErrorResponse() async throws {
        let probe = CoreCallConcurrencyProbe(failingAction: "configure")
        let store = LogseqStore { request in
            probe.call(request, delayingAction: "configure")
        }

        store.configure(
            baseURL: "https://api-staging.logseq.io",
            token: "token",
            refreshAfterApply: false
        )
        try await waitUntil {
            probe.events.contains("start configure")
        }
        Task { _ = await store.selectGraphAndWait("after error") }

        try await waitUntil(timeout: 2.0) {
            probe.events.contains("finish selectGraph")
        }
        try await waitUntil(timeout: 2.0) {
            store.snapshot.selectedGraphId == "after error" && store.lastError == nil
        }
        #expect(probe.maximumConcurrentCalls == 1)
        #expect(probe.events == [
            "start configure",
            "finish configure",
            "start selectGraph",
            "finish selectGraph",
        ])
        #expect(store.snapshot.selectedGraphId == "after error")
        #expect(store.lastError == nil)
    }

    @Test @MainActor func nativeCoreCallsAreSerializedAcrossStoreInstances() async throws {
        let probe = CoreCallConcurrencyProbe()
        let firstStore = LogseqStore { request in
            probe.call(request, delayingAction: "configure")
        }
        let secondStore = LogseqStore { request in
            probe.call(request, delayingAction: "configure")
        }

        firstStore.configure(
            baseURL: "https://api-staging.logseq.io",
            token: "token",
            refreshAfterApply: false
        )
        try await waitUntil {
            probe.events.contains("start configure")
        }
        Task { _ = await secondStore.selectGraphAndWait("queued across stores") }

        try await waitUntil(timeout: 2.0) {
            probe.events.contains("finish selectGraph")
        }
        #expect(probe.maximumConcurrentCalls == 1)
        #expect(probe.events == [
            "start configure",
            "finish configure",
            "start selectGraph",
            "finish selectGraph",
        ])
    }

    @Test @MainActor func nativeCoreCallsStayOnOneOperatingSystemThreadAcrossStores() async throws {
        let probe = CoreCallConcurrencyProbe()
        let firstStore = LogseqStore { request in
            probe.call(request, delayingAction: "never")
        }
        let secondStore = LogseqStore { request in
            probe.call(request, delayingAction: "never")
        }

        for index in 0..<4 {
            let store = index % 2 == 0 ? firstStore : secondStore
            Task { _ = await store.selectGraphAndWait("thread-affinity-\(index)") }
        }

        try await waitUntil(timeout: 2.0) {
            probe.finishedCallCount == 4
        }
        #expect(probe.operatingSystemThreadIDs.count == 1)
        #expect(probe.operatingSystemThreadNames == ["LogseqCore"])
    }

    @Test @MainActor func nativeStoreRequestsCoreOwnedSnapshots() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return outlineSnapshotJSON(blocks: [], appliedServerT: 51)
        }
        store.refreshSoon()
        try await waitUntil { !recorder.all.isEmpty }
        let request = try #require(recorder.all.first)
        let json = try #require(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        let params = try #require(json["params"] as? [String: Any])
        #expect(params["projection"] as? String == "snapshot")
    }

    @Test func outlinerProjectionDecodesCoreOwnedStateAndRows() throws {
        let response = try JSONDecoder().decode(
            LogseqRPCResponse.self,
            from: Data(#"""
            {"apiVersion":1,"ok":true,"result":{"revision":1,"query":"","blocks":[],
            "selectedBlock":null,"lastRefreshAt":null,"isSearching":false,
            "outlinerState":{"editing":{"uuid":"child","title":"Draft","caretUTF16Offset":5},
            "selectedBlockIds":["child"],"autocomplete":null,
            "collapsedBlockIds":["root"],"zoomedBlockIds":["root"]},
            "outlinerRows":[{"block":{"uuid":"root","title":"Root",
            "pageId":"page","parentId":"page","order":"a0","createdAt":1,"updatedAt":1,
            "syncStatus":"synced"},"depth":0,"hasChildren":true,"isCollapsed":true}],
            "outlinerCommandRevision":2,"outlinerCommands":[{"type":"haptic","style":"impact"}]},
            "error":null}
            """#.utf8)
        )
        let snapshot = try #require(response.result)
        #expect(snapshot.outlinerState.editing?.title == "Draft")
        #expect(snapshot.outlinerState.collapsedBlockIds == ["root"])
        #expect(snapshot.outlinerState.zoomedBlockIds == ["root"])
        #expect(snapshot.outlinerState.zoomedBlockId == "root")
        #expect(snapshot.outlinerRows.map(\.block.uuid) == ["root"])
        #expect(snapshot.outlinerRows[0].isCollapsed)
        #expect(snapshot.outlinerCommands[0].style == "impact")
    }

}

private func outlineBlockJSON(
    uuid: String,
    title: String? = nil,
    parentID: String,
    order: String,
    createdAt: Int
) -> String {
    """
    {"uuid":"\(uuid)","title":"\(title ?? uuid)","pageId":"page",\
    "parentId":"\(parentID)","order":"\(order)","createdAt":\(createdAt),\
    "updatedAt":\(createdAt),"syncStatus":"synced"}
    """
}

private func outlineSnapshotJSON(blocks: [String], appliedServerT: Int? = 48192) -> String {
    let cursor = appliedServerT.map { String($0) } ?? "null"
    let rows = blocks.map { block in
        "{\"block\":\(block),\"depth\":0,\"hasChildren\":false,\"isCollapsed\":false}"
    }
    return """
    {"apiVersion":1,"ok":true,"result":{"revision":1,"query":"","blocks":[\
    \(blocks.joined(separator: ","))],"selectedBlock":null,"lastRefreshAt":null,\
    "graphName":"Test","isSearching":false,"appliedServerT":\(cursor),\
    "outlinerRows":[\(rows.joined(separator: ","))]},"error":null}
    """
}

private func outlinerSnapshotJSON(revision: Int, title: String) -> String {
    """
    {"apiVersion":1,"ok":true,"result":{"revision":\(revision),"query":"","blocks":[],
    "selectedBlock":null,"lastRefreshAt":null,"isSearching":false,
    "outlinerState":{"editing":{"uuid":"block","title":"\(title)","caretUTF16Offset":3},
    "selectedBlockIds":[],"autocomplete":null,"collapsedBlockIds":[],"zoomedBlockIds":[]}},
    "error":null}
    """
}

private func outlinerEditingSnapshotJSON(revision: Int, uuid: String, title: String) -> String {
    """
    {"apiVersion":1,"ok":true,"result":{"revision":\(revision),"query":"","blocks":[],
    "selectedBlock":null,"lastRefreshAt":null,"isSearching":false,
    "outlinerState":{"editing":{"uuid":"\(uuid)","title":"\(title)","caretUTF16Offset":0},
    "selectedBlockIds":[],"autocomplete":null,"collapsedBlockIds":[],"zoomedBlockIds":[]}},
    "error":null}
    """
}

private actor SuspendedPendingTransport {
    private var continuation: CheckedContinuation<Void, Never>?
    private var cancelled = false

    var hasStarted: Bool { continuation != nil }
    var isWaiting: Bool { continuation != nil }
    var wasCancelled: Bool { cancelled }

    func send(_ request: LogseqPendingSyncRequest) async -> LogseqPendingSyncResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
        if cancelled {
            return LogseqPendingSyncResult(status: nil, body: nil, error: "cancelled")
        }
        return LogseqPendingSyncResult(status: 201, body: #"{"uuid":"local-1"}"#, error: nil)
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: ())
    }

    private func cancel() {
        cancelled = true
        resume()
    }
}

private func requestPayloadString(_ request: String) -> String? {
    let envelope = try? JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
    return (envelope?["params"] as? [String: Any])?["payload"] as? String
}

private func requestPayloadObject(_ request: String) -> [String: Any]? {
    guard let payload = requestPayloadString(request) else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
}

private func pendingPumpSnapshot(
    query: String,
    syncStatus: String,
    request: LogseqPendingSyncRequest?,
    error: String? = nil
) -> String {
    let requestJSON: String
    if let request,
       let data = try? JSONEncoder().encode(request),
       let json = String(data: data, encoding: .utf8) {
        requestJSON = json
    } else {
        requestJSON = "null"
    }
    return """
    {
      "apiVersion": 1,
      "ok": true,
      "result": {
        "revision": 1,
        "syncConnected": true,
        "searchQuery": "\(query)",
        "blocks": [{
          "uuid": "local-1",
          "title": "Offline capture",
          "pageId": "journal/2026-08-13",
          "createdAt": 1776000000000,
          "updatedAt": 1776000000000,
          "syncStatus": "\(syncStatus)"
        }],
        "selectedBlock": null,
        "lastRefreshAt": 1776000000000,
        "graphName": "Test",
        "isSearching": \(!query.isEmpty),
        "pendingSyncRequest": \(requestJSON),
        "pendingSyncError": \(String(data: try! JSONEncoder().encode(error), encoding: .utf8)!)
      },
      "error": null
    }
    """
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var first: String? {
        lock.lock()
        defer { lock.unlock() }
        return values.first
    }

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

private final class CoreCallConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let failingAction: String?
    private let callDelay: TimeInterval
    private var activeCalls = 0
    private var maximumActiveCalls = 0
    private var recordedEvents: [String] = []
    private var recordedOperatingSystemThreadIDs: Set<UInt64> = []
    private var recordedOperatingSystemThreadNames: Set<String> = []

    init(failingAction: String? = nil, callDelay: TimeInterval = 0) {
        self.failingAction = failingAction
        self.callDelay = callDelay
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    var maximumConcurrentCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveCalls
    }

    var finishedCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents.count { $0.hasPrefix("finish ") }
    }

    var operatingSystemThreadIDs: Set<UInt64> {
        lock.lock()
        defer { lock.unlock() }
        return recordedOperatingSystemThreadIDs
    }

    var operatingSystemThreadNames: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return recordedOperatingSystemThreadNames
    }

    func call(_ request: String, delayingAction: String) -> String {
        let decoded = try? JSONDecoder().decode(TestRPCRequest.self, from: Data(request.utf8))
        let action = decoded?.params.action ?? decoded?.method ?? "unknown"

        lock.lock()
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        recordedEvents.append("start \(action)")
        recordedOperatingSystemThreadIDs.insert(UInt64(pthread_mach_thread_np(pthread_self())))
        recordedOperatingSystemThreadNames.insert(Thread.current.name ?? "")
        lock.unlock()

        if action == delayingAction {
            Thread.sleep(forTimeInterval: 0.2)
        } else if callDelay > 0 {
            Thread.sleep(forTimeInterval: callDelay)
        }

        lock.lock()
        recordedEvents.append("finish \(action)")
        activeCalls -= 1
        lock.unlock()

        if action == failingAction {
            return #"{"apiVersion":1,"ok":false,"result":null,"error":{"code":"test_error","message":"Expected test failure"}}"#
        }
        let query = action == "selectGraph" ? (decoded?.params.payload ?? "") : ""
        return """
        {
          "apiVersion": 1,
          "ok": true,
          "result": {
            "revision": 1,
            "selectedGraphId": "\(query)",
            "blocks": [],
            "selectedBlock": null,
            "lastRefreshAt": null,
            "graphName": "probe"
          },
          "error": null
        }
        """
    }
}

private struct TestRPCRequest: Decodable {
    let method: String
    let params: TestRPCParams
}

private struct TestRPCParams: Decodable {
    let action: String?
    let payload: String?
}

@MainActor private func capture(_ store: LogseqStore, _ text: String) {
    Task { _ = await store.captureSharedText(text, id: UUID().uuidString.lowercased()) }
}

private func latestCaptureUUID(in recorder: RequestRecorder) -> String? {
    for request in recorder.all.reversed() {
        guard let decoded = try? JSONDecoder().decode(TestRPCRequest.self, from: Data(request.utf8)),
              decoded.params.action == "captureShared",
              let payload = requestPayloadObject(request), let uuid = payload["uuid"] as? String else { continue }
        return uuid
    }
    return nil
}

@MainActor private func waitUntil(
    timeout: TimeInterval = 1.0,
    _ predicate: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(predicate())
}

private func waitUntilAsync(
    timeout: TimeInterval = 1.0,
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(await predicate())
}

struct TestData : Codable, Hashable {
    var testModuleName: String
}

@Suite(.serialized) struct LogseqRuntimeLogTests {
    @Test func boundsFiltersAndOrdersRuntimeRecords() {
        let log = LogseqRuntimeLog(capacity: 2)
        log.append(level: .info, source: .ui, message: "first", timestampMilliseconds: 1)
        log.append(level: .error, source: .core, message: "second", timestampMilliseconds: 2)
        log.append(level: .info, source: .core, message: "third", timestampMilliseconds: 3)

        #expect(log.records().map(\.message) == ["second", "third"])
        #expect(log.records(source: .core, errorsOnly: true).map(\.message) == ["second"])
        #expect(log.records(source: .core, newestFirst: true).map(\.message) == ["third", "second"])
        #expect(log.exportText().contains("ERROR core second"))
    }
}

@Suite(.serialized) struct LogseqCoreExecutorTests {
    @Test func synchronousAndAsynchronousCallsUseTheSameSerialThread() async throws {
        let recorder = RequestRecorder()
        let releaseFirst = DispatchSemaphore(value: 0)

        let first = Task {
            await LogseqCoreExecutor.shared.call(
                { _ in
                    recorder.append("first started")
                    releaseFirst.wait()
                    return "first"
                },
                requestJSON: "first"
            )
        }
        try await waitUntilAsync { recorder.all.contains("first started") }

        let second = Task.detached {
            LogseqCoreExecutor.shared.callSync(
                { _ in
                    recorder.append("second started")
                    return "second"
                },
                requestJSON: "second"
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!recorder.all.contains("second started"))

        releaseFirst.signal()
        #expect(await first.value == "first")
        #expect(await second.value == "second")
        #expect(recorder.all.contains("second started"))
    }
}
