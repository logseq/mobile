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

    @Test func builtInTaskStatusesMatchLogseq() {
        #expect(LogseqTaskStatus.builtIn.map(\.title) == [
            "Backlog", "Todo", "Doing", "In Review", "Done", "Canceled"
        ])
        #expect(LogseqTaskStatus.builtIn.compactMap { $0.icon?.id } == [
            "Backlog", "Todo", "InProgress50", "InReview", "Done", "Cancelled"
        ])
    }

    @Test func snapshotDecodesCustomTaskStatusCatalog() throws {
        let data = Data(##"{"revision":1,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Test","isSearching":false,"taskStatuses":[{"uuid":"status-1","ident":"user.status/waiting","title":"Waiting","icon":{"type":"tabler-icon","id":"clock","color":"#7c3aed"}}]}"##.utf8)
        let snapshot = try JSONDecoder().decode(LogseqSnapshot.self, from: data)
        #expect(snapshot.taskStatuses?.first?.title == "Waiting")
        #expect(snapshot.taskStatuses?.first?.icon?.color == "#7c3aed")
    }

    @Test func taskStatusChoicesPreferGraphCatalogIdentityOverFallbacks() {
        let graphTodo = LogseqTaskStatus(
            uuid: "8e7f7d42-graph-todo",
            ident: "logseq.property/status.todo",
            title: "Todo",
            icon: LogseqIcon(type: "tabler-icon", id: "circle")
        )
        let waiting = LogseqTaskStatus(
            uuid: "custom-waiting",
            ident: "user.status/waiting",
            title: "Waiting",
            icon: nil
        )
        let statusWithoutIdent = LogseqTaskStatus(
            uuid: "custom-without-ident",
            ident: nil,
            title: "Custom",
            icon: nil
        )

        let choices = LogseqTaskStatus.availableChoices(
            catalog: [graphTodo, waiting, statusWithoutIdent, statusWithoutIdent]
        )

        #expect(choices.first?.uuid == graphTodo.uuid)
        #expect(choices.contains { $0.uuid == waiting.uuid })
        #expect(choices.filter { $0.uuid == statusWithoutIdent.uuid }.count == 1)
        #expect(!choices.contains { $0.uuid == LogseqTaskStatus.todo.uuid })
        #expect(choices.filter { $0.ident == graphTodo.ident }.count == 1)
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

    @Test @MainActor func loadingFlashcardsUsesTheRequestedReviewTime() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"loadFlashcards\"") {
                return #"{"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Test","flashcards":[{"block":{"uuid":"card-1","title":"Question","pageId":"page","createdAt":1,"updatedAt":1,"syncStatus":"synced","isAsset":false},"children":[],"due":1776000000000,"repetitions":0,"lapses":0,"state":"new"}]}}"#
            }
            return testEmptySnapshotJSON
        }

        store.loadFlashcards(now: 1_776_000_000_000)

        try await waitUntil {
            store.snapshot.flashcards.count == 1 && recorder.all.contains {
                $0.contains("\"action\":\"loadFlashcards\"")
                    && $0.contains("\"payload\":\"1776000000000\"")
            }
        }
        #expect(store.snapshot.flashcards.first?.block.uuid == "card-1")
    }

    @Test @MainActor func reviewingFlashcardStagesOneAtomicSemanticOperation() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return testEmptySnapshotJSON
        }

        store.reviewFlashcard(
            uuid: "card-1",
            rating: "good",
            now: 1_776_000_000_000,
            operationID: "review-1"
        )

        try await waitUntil {
            recorder.all.contains {
                $0.contains("\"action\":\"reviewFlashcard\"")
                    && $0.contains("card-1")
                    && $0.contains("good")
                    && $0.contains("review-1")
            }
        }
    }

    @Test @MainActor func settingPageFavoriteStagesOneSemanticOperation() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return testEmptySnapshotJSON
        }

        store.setPageFavorite(
            pageUUID: "page-1",
            favorite: true,
            now: 1_776_000_000_000,
            operationID: "favorite-1"
        )

        try await waitUntil {
            recorder.all.contains {
                $0.contains("\"action\":\"setPageFavorite\"")
                    && $0.contains("page-1")
                    && $0.contains("\"favorite\":true")
                    && $0.contains("favorite-1")
            }
        }
    }

    @Test @MainActor func deletingPageStagesOneSemanticOperation() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return testEmptySnapshotJSON
        }

        store.deletePage(
            pageUUID: "page-1",
            now: 1_776_000_000_000,
            operationID: "delete-page-1"
        )

        try await waitUntil {
            recorder.all.contains {
                $0.contains("\"action\":\"deletePage\"")
                    && $0.contains("page-1")
                    && $0.contains("delete-page-1")
            }
        }
    }

    @Test @MainActor func selectingGraphUsesExplicitGraphID() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return testEmptySnapshotJSON
        }
        store.selectGraph("plain-1")
        try await waitUntil {
            recorder.all.contains {
                $0.contains("\"action\":\"selectGraph\"")
                    && $0.contains("\"payload\":\"plain-1\"")
            }
        }
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

    @Test func snapshotMetadataRequestUsesSyncAPIAndOAuthBearerToken() throws {
        let request = try LogseqGraphSyncHTTP.snapshotMetadataRequest(
            baseURL: "http://127.0.0.1:8787/api",
            graphID: "plain graph",
            accessToken: "oauth-token"
        )
        #expect(request.url?.absoluteString == "http://127.0.0.1:8787/sync/plain%20graph/snapshot/download")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-token")

        let cursor = try LogseqGraphSyncHTTP.snapshotCursorRequest(
            baseURL: "http://127.0.0.1:8787/api",
            graphID: "plain graph",
            accessToken: "oauth-token"
        )
        #expect(cursor.url?.absoluteString == "http://127.0.0.1:8787/sync/plain%20graph/pull?since=9007199254740991")
        #expect(cursor.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-token")
    }

    @Test func snapshotImportMetadataCombinesCurrentServerResponses() throws {
        let body = try LogseqGraphSyncHTTP.importMetadataBody(
            snapshotMetadataBody: #"{"ok":true,"key":"stream/graph.snapshot","url":"/sync/graph/snapshot/stream","schema-version":"65.33","content-encoding":"gzip"}"#,
            pullBody: #"{"type":"pull/ok","t":48192,"txs":[]}"#,
            rowCount: 7
        )
        let json = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(json["t"] as? Int == 48192)
        #expect(json["schema-version"] as? String == "65.33")
        #expect(json["row-count"] as? Int == 7)
        #expect(json["content-encoding"] as? String == "gzip")
    }

    @Test func snapshotImportMetadataAcceptsTheDevDownloadContract() throws {
        let body = try LogseqGraphSyncHTTP.importMetadataBody(
            snapshotMetadataBody: #"{"ok":true,"url":"/sync/graph/snapshot/stream"}"#,
            pullBody: #"{"type":"pull/ok","t":10,"txs":[]}"#,
            rowCount: nil
        )
        let json = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(json["t"] as? Int == 10)
        #expect(json["schema-version"] == nil)
        #expect(json["row-count"] == nil)
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

    @Test func graphSnapshotRefreshWaitsForOutlinerEditingToFinish() {
        #expect(!LogseqGraphSnapshotRefreshPolicy.shouldApplyDownloadedSnapshot(
            forceSnapshot: true,
            isEditingOutlinerBlock: true,
            hasPendingLocalChanges: false
        ))
        #expect(LogseqGraphSnapshotRefreshPolicy.shouldApplyDownloadedSnapshot(
            forceSnapshot: true,
            isEditingOutlinerBlock: false,
            hasPendingLocalChanges: false
        ))
        #expect(LogseqGraphSnapshotRefreshPolicy.shouldApplyDownloadedSnapshot(
            forceSnapshot: true,
            isEditingOutlinerBlock: false,
            hasPendingLocalChanges: true
        ))
    }

    @Test func outlinerTypingAutosavesAfterOneSecondOfIdle() {
        #expect(LogseqOutlinerAutosavePolicy.serverSyncDelayNanoseconds(
            eventType: "textChanged"
        ) == 1_000_000_000)
        #expect(LogseqOutlinerAutosavePolicy.serverSyncDelayNanoseconds(
            eventType: "returnPressed"
        ) == 1_000_000_000)
        #expect(LogseqOutlinerAutosavePolicy.serverSyncDelayNanoseconds(
            eventType: "backspacePressed"
        ) == 1_000_000_000)
        #expect(LogseqOutlinerAutosavePolicy.serverSyncDelayNanoseconds(
            eventType: "toolbar"
        ) == 150_000_000)
    }

    @Test func pendingPumpRestartsWhenWorkArrivesDuringTaskCleanup() {
        #expect(LogseqPendingSyncPumpPolicy.shouldRestartAfterFinishing(
            requestedWhileFinishing: true
        ))
        #expect(!LogseqPendingSyncPumpPolicy.shouldRestartAfterFinishing(
            requestedWhileFinishing: false
        ))
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

    @Test @MainActor func authenticatedStartupDoesNotReopenAnAlreadyRestoredGraph() async throws {
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
            if request.contains("\"action\":\"openGraph\"") {
                result = #"{"revision":2,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Sync 2","selectedGraphId":"plain-1","graphs":[{"id":"plain-1","name":"Sync 2","isEncrypted":false,"isReady":true}],"appliedServerT":42,"isSearching":false}"#
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
            $0.contains("\"action\":\"openGraph\"")
        }
        #expect(openGraphRequests.count == 1)
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

    @Test @MainActor func navigationAndRelatedActionsDispatchTheirExactCoreCommands() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return testEmptySnapshotJSON
        }
        let block = LogseqBlock(
            uuid: "block-1",
            title: "Block",
            pageId: "page-1",
            parentId: "page-1",
            createdAt: 1,
            updatedAt: 1,
            syncStatus: nil
        )

        store.selectPage("page-1")
        store.openNode("block-1")
        store.loadOlderJournals()
        store.clearSelectedPage()
        await store.unlockGraph("secret")
        store.select(block)
        store.clearSelection()
        store.clearRelated()

        try await waitUntil { recorder.all.count >= 8 }

        let expectedActionsAndPayloads: [(String, String?)] = [
            ("selectPage", "page-1"),
            ("openNode", #"{\"uuid\":\"block-1\"}"#),
            ("loadOlderJournals", nil),
            ("clearSelectedPage", nil),
            ("unlockGraph", "secret"),
            ("select", "block-1"),
            ("clearSelection", nil),
            ("clearRelated", nil),
        ]
        for (action, payload) in expectedActionsAndPayloads {
            let request = try #require(recorder.all.first {
                $0.contains("\"action\":\"\(action)\"")
            })
            if let payload {
                #expect(request.contains("\"payload\":\"\(payload)\""))
            }
        }
    }

    @Test @MainActor func journalPaginationAvailabilitySurvivesSnapshotMerging() async throws {
        let store = LogseqStore { _ in
            #"{"apiVersion":1,"ok":true,"result":{"revision":2,"query":"","blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Sync 2","isSearching":false,"hasOlderJournals":true},"error":null}"#
        }

        store.loadOlderJournals()

        try await waitUntil { store.snapshot.revision == 2 }
        #expect(store.snapshot.hasOlderJournals)
    }

    @Test @MainActor func taskAndAssetCreationDispatchDurableCoreWrites() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return testEmptySnapshotJSON
        }
        store.sendTask("Follow up", status: LogseqTaskStatus.todo)
        let assetUUID = store.addAsset(
            title: "photo.jpg",
            assetType: "jpg",
            assetSize: 2048,
            assetChecksum: "abc",
            localPath: "/documents/photo.jpg",
            targetBlockId: "editing-block"
        )
        #expect(store.snapshot.blocks.isEmpty)
        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"sendTask\"") }
                && recorder.all.contains { $0.contains("\"action\":\"addAsset\"") }
        }
        let assetRequest = try #require(
            recorder.all.last { $0.contains("\"action\":\"addAsset\"") }
        )
        #expect(UUID(uuidString: try #require(extractSendUUID(from: assetRequest))) != nil)
        #expect(assetUUID == extractSendUUID(from: assetRequest))
        #expect(assetRequest.contains(#"\"targetBlockId\":\"editing-block\""#))

        let transcriptUUID = store.addChildBlock("Transcript", parentId: assetUUID)
        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"addChildBlock\"") }
        }
        let transcriptRequest = try #require(
            recorder.all.last { $0.contains("\"action\":\"addChildBlock\"") }
        )
        #expect(transcriptUUID == extractSendUUID(from: transcriptRequest))
        #expect(transcriptRequest.contains(#"\"parentId\":\"\#(assetUUID)\""#))
    }

    @Test @MainActor func updateBlockTitleAppliesCoreSnapshot() async throws {
        let block = LogseqBlock(
            uuid: "block-1",
            title: "Draft title",
            pageId: "page-1",
            parentId: nil,
            createdAt: 1_776_000_000_000,
            updatedAt: 1_776_000_000_000,
            syncStatus: "synced"
        )
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 2,
                "query": "",
                "blocks": [
                  {
                    "uuid": "block-1",
                    "title": "Published title",
                    "pageId": "page-1",
                    "createdAt": 1776000000000,
                    "updatedAt": 1776000100000
                  }
                ],
                "selectedBlock": null,
                "lastRefreshAt": 1776000100000,
                "isSearching": false
              },
              "error": null
            }
            """
        }

        store.update(block: block, title: "Published title")

        try await waitUntil {
            recorder.first?.contains("\"action\":\"updateBlock\"") == true
                && store.snapshot.blocks.first?.title == "Published title"
        }

        let capturedRequest = try #require(recorder.first)
        #expect(capturedRequest.contains("\"action\":\"updateBlock\""))
        #expect(capturedRequest.contains("\\\"uuid\\\":\\\"block-1\\\""))
        #expect(capturedRequest.contains("\\\"expectedTitle\\\":\\\"Draft title\\\""))
        #expect(capturedRequest.contains("\\\"operationId\\\":"))
        #expect(capturedRequest.contains("\\\"title\\\":\\\"Published title\\\""))
        #expect(store.snapshot.blocks.first?.title == "Published title")
        #expect(store.snapshot.blocks.first?.updatedAt == 1_776_000_100_000)
    }

    @Test @MainActor func taskStatusPublishesOnlyTheDurableCoreProjection() async throws {
        let recorder = RequestRecorder()
        let waiting = LogseqTaskStatus(
            uuid: "custom-waiting",
            ident: "user.status/waiting",
            title: "Waiting",
            icon: LogseqIcon(type: "tabler-icon", id: "clock", color: "#7c3aed")
        )
        let store = LogseqStore { request in
            recorder.append(request)
            let status = request.contains("\"action\":\"updateBlockStatus\"")
                || request.contains("\"action\":\"beginPendingSync\"")
                ? ##"{"uuid":"custom-waiting","ident":"user.status/waiting","title":"Waiting","icon":{"type":"tabler-icon","id":"clock","color":"#7c3aed"}}"##
                : ##"{"uuid":"todo","ident":"logseq.property/status.todo","title":"Todo"}"##
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 2,
                "query": "",
                "blocks": [{
                  "uuid": "task-1",
                  "kind": "task",
                  "title": "Follow up",
                  "pageId": "journal-1",
                  "createdAt": 1776000000000,
                  "updatedAt": 1776000100000,
                  "status": \(status)
                }],
                "selectedBlock": null,
                "lastRefreshAt": 1776000100000,
                "isSearching": false
              },
              "error": null
            }
            """
        }
        store.open(path: "/tmp/status-test.sqlite")
        try await waitUntil {
            store.snapshot.blocks.first?.uuid == "task-1"
        }
        let block = try #require(store.snapshot.blocks.first)

        store.updateStatus(block: block, status: waiting)

        #expect(store.snapshot.blocks.first?.status?.uuid == "todo")
        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"updateBlockStatus\"") }
                && store.snapshot.blocks.first?.status?.uuid == "custom-waiting"
        }
        #expect(store.snapshot.blocks.first?.status?.uuid == "custom-waiting")
        let request = try #require(
            recorder.all.last { $0.contains("\"action\":\"updateBlockStatus\"") }
        )
        #expect(request.contains("\\\"uuid\\\":\\\"task-1\\\""))
        #expect(request.contains("\\\"expectedStatusUuid\\\":\\\"todo\\\""))
        #expect(request.contains("expectedStatusIdent"))
        #expect(request.contains("status.todo"))
        #expect(request.contains("\\\"operationId\\\":"))
        #expect(request.contains("\\\"uuid\\\":\\\"custom-waiting\\\""))
        #expect(request.contains("\\\"iconColor\\\":\\\"#7c3aed\\\""))
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

    @Test @MainActor func updateBlockTitleDoesNotBlockTheMainActorWhenCoreIsSlow() async throws {
        let block = LogseqBlock(
            uuid: "block-1",
            title: "Draft title",
            pageId: "page-1",
            parentId: nil,
            createdAt: 1_776_000_000_000,
            updatedAt: 1_776_000_000_000,
            syncStatus: "synced"
        )
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"updateBlock\"") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 2,
                "query": "",
                "blocks": [
                  {
                    "uuid": "block-1",
                    "title": "Published title",
                    "pageId": "page-1",
                    "createdAt": 1776000000000,
                    "updatedAt": 1776000100000
                  }
                ],
                "selectedBlock": null,
                "lastRefreshAt": 1776000100000,
                "isSearching": false
              },
              "error": null
            }
            """
        }

        let start = Date()
        store.update(block: block, title: "Published title")
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.1)
        try await waitUntil {
            recorder.first?.contains("\"action\":\"updateBlock\"") == true
                && store.snapshot.blocks.first?.title == "Published title"
        }
    }

    @Test @MainActor func sendPublishesCoreResultBeforeSyncing() async throws {
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

        store.send("Offline capture")

        try await waitUntil {
            recorder.first?.contains("\"action\":\"send\"") == true
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

    @Test @MainActor func pendingSyncPatchPreservesTheOfflineEditedGraph() async throws {
        let recorder = RequestRecorder()
        let beginPatch = """
        {"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],"selectedBlock":null,"pendingSyncRequest":{"id":1,"method":"POST","url":"https://api.example/capture","body":"{}","token":"access-token","filePath":null,"contentType":"application/json"},"hasPendingSemanticOperations":true,"isPendingSyncPatch":true},"error":null}
        """
        let completePatch = """
        {"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],"selectedBlock":null,"appliedServerT":43,"pendingSyncRequest":null,"hasPendingSemanticOperations":false,"isPendingSyncPatch":true},"error":null}
        """
        let store = LogseqStore(
            call: { call in
                recorder.append(call)
                if call.contains("\"action\":\"beginPendingSync\"") {
                    return beginPatch
                }
                if call.contains("\"action\":\"completePendingSync\"") {
                    return completePatch
                }
                return pendingPumpSnapshot(query: "", syncStatus: "pending", request: nil)
            },
            pendingTransport: { _ in
                LogseqPendingSyncResult(status: 201, body: #"{"uuid":"local-1"}"#, error: nil)
            }
        )

        store.send("Offline capture")

        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"completePendingSync\"") }
        }
        #expect(store.snapshot.blocks.first?.title == "Offline capture")
        #expect(store.snapshot.appliedServerT == 43)
    }

    @Test @MainActor func sendDoesNotBlockTheMainActorWhenCoreIsSlow() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"send\"") {
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
        store.send("Slow local capture")
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.1)
        #expect(store.snapshot.blocks.isEmpty)
        try await waitUntil {
            recorder.first?.contains("\"action\":\"send\"") == true
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
                if request.contains("\"action\":\"searchNodes\"") {
                    return pendingPumpSnapshot(query: "local", syncStatus: "pending", request: nil)
                }
                return pendingPumpSnapshot(query: "", syncStatus: "pending", request: nil)
            },
            pendingTransport: { request in
                await transport.send(request)
            }
        )

        store.send("Offline capture")
        try await waitUntilAsync { await transport.hasStarted }

        store.openNode("page-1")
        _ = store.addChildBlock("Offline child", parentId: "local-1")
        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"openNode\"") }
                && recorder.all.contains { $0.contains("\"action\":\"addChildBlock\"") }
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
        store.refresh()
        try await waitUntil { store.snapshot.appliedServerT == 51 }

        _ = await store.runGraphEventsOnce(
            graphID: "graph-1",
            baseURL: "://",
            accessToken: "access-token"
        )

        #expect(store.lastError == nil)
        #expect(store.syncError?.code == "invalid_sync_transport")
        #expect(store.syncError?.message == "The sync server address is invalid.")
        store.openNode("page-1")
        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"openNode\"") }
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

    @Test @MainActor func sendPublishesOnlyAfterTheLocalWriteIsDurable() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"send\"") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            let uuid = latestSendUUID(in: recorder) ?? "local-durable"
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
        store.send("Durable capture")

        #expect(Date().timeIntervalSince(start) < 0.1)
        #expect(store.snapshot.blocks.isEmpty)
        try await waitUntil {
            store.snapshot.blocks.first?.title == "Durable capture"
                && store.snapshot.blocks.first?.isPendingSync == true
        }
    }

    @Test @MainActor func searchNodesDispatchesCacheOnlySearch() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "searchQuery": "offline",
                "blocks": [],
                "selectedBlock": null,
                "lastRefreshAt": null,
                "graphName": null,
                "isSearching": true
              },
              "error": null
            }
            """
        }

        store.searchNodes("offline")

        try await waitUntil {
            recorder.first?.contains("\"action\":\"searchNodes\"") == true
                && store.snapshot.searchQuery == "offline"
        }

        let request = try #require(recorder.first)
        #expect(request.contains("\"action\":\"searchNodes\""))
        #expect(!request.contains("\"action\":\"search\""))
        #expect(store.snapshot.searchQuery == "offline")
    }

    @Test @MainActor func searchNodesDoesNotBlockTheMainActorWhenCoreIsSlow() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"searchNodes\"") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "searchQuery": "slow",
                "blocks": [],
                "selectedBlock": null,
                "lastRefreshAt": null,
                "graphName": null,
                "isSearching": true
              },
              "error": null
            }
            """
        }

        let start = Date()
        store.searchNodes("slow")
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.05)
        try await waitUntil {
            recorder.first?.contains("\"action\":\"searchNodes\"") == true
                && store.snapshot.searchQuery == "slow"
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

        store.refresh()
        store.refresh()

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
        store.searchNodes("queued")
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.1)
        try await waitUntil(timeout: 2.0) {
            probe.events.contains("finish searchNodes")
        }
        #expect(probe.maximumConcurrentCalls == 1)
        #expect(probe.events == [
            "start configure",
            "finish configure",
            "start searchNodes",
            "finish searchNodes",
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
        store.selectPage("page-1")

        try await waitUntil(timeout: 2.0) {
            probe.events.contains("finish selectPage")
                && probe.events.filter { $0 == "finish configure" }.count == 2
        }
        #expect(probe.maximumConcurrentCalls == 1)
        #expect(probe.events == [
            "start configure",
            "finish configure",
            "start selectPage",
            "finish selectPage",
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
        store.searchNodes("after error")

        try await waitUntil(timeout: 2.0) {
            probe.events.contains("finish searchNodes")
        }
        try await waitUntil(timeout: 2.0) {
            store.snapshot.searchQuery == "after error" && store.lastError == nil
        }
        #expect(probe.maximumConcurrentCalls == 1)
        #expect(probe.events == [
            "start configure",
            "finish configure",
            "start searchNodes",
            "finish searchNodes",
        ])
        #expect(store.snapshot.searchQuery == "after error")
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
        secondStore.searchNodes("queued across stores")

        try await waitUntil(timeout: 2.0) {
            probe.events.contains("finish searchNodes")
        }
        #expect(probe.maximumConcurrentCalls == 1)
        #expect(probe.events == [
            "start configure",
            "finish configure",
            "start searchNodes",
            "finish searchNodes",
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
            store.searchNodes("thread-affinity-\(index)")
        }

        try await waitUntil(timeout: 2.0) {
            probe.finishedCallCount == 4
        }
        #expect(probe.operatingSystemThreadIDs.count == 1)
        #expect(probe.operatingSystemThreadNames == ["LogseqCore"])
    }

    @Test @MainActor func searchNodesKeepsDurableCaptureVisible() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"searchNodes\"") {
                let uuid = latestSendUUID(in: recorder) ?? "local-search"
                return """
                {
                  "apiVersion": 1,
                  "ok": true,
                  "result": {
                    "revision": 1,
                    "searchQuery": "E2E capture",
                    "blocks": [{
                      "uuid": "\(uuid)",
                      "title": "E2E capture responsive",
                      "pageId": "journal/2026-08-13",
                      "createdAt": 1776000000000,
                      "updatedAt": 1776000000000,
                      "syncStatus": "pending"
                    }],
                    "selectedBlock": null,
                    "lastRefreshAt": null,
                    "graphName": "pat test",
                    "isSearching": true
                  },
                  "error": null
                }
                """
            }
            if request.contains("\"action\":\"send\"") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            let uuid = latestSendUUID(in: recorder) ?? "local-search"
            return """
            {
              "apiVersion": 1,
              "ok": true,
              "result": {
                "revision": 1,
                "query": "",
                "blocks": [{
                  "uuid": "\(uuid)",
                  "title": "E2E capture responsive",
                  "pageId": "journal/2026-08-13",
                  "createdAt": 1776000000000,
                  "updatedAt": 1776000000000,
                  "syncStatus": "pending"
                }],
                "selectedBlock": null,
                "lastRefreshAt": null,
                "graphName": "pat test",
                "isSearching": false
              },
              "error": null
            }
            """
        }

        store.send("E2E capture responsive")
        try await waitUntil {
            store.snapshot.blocks.first?.title == "E2E capture responsive"
        }

        store.searchNodes("E2E capture")

        try await waitUntil {
            recorder.all.contains { $0.contains("\"action\":\"searchNodes\"") }
                && store.snapshot.searchQuery == "E2E capture"
        }

        #expect(store.snapshot.blocks.map(\.title).contains("E2E capture responsive"))
    }

    @Test func contentModeTogglesBetweenLogseqAndOutliner() {
        #expect(LogseqContentMode.defaultMode == .outliner)
        #expect(LogseqContentMode.logseq.toggled == .outliner)
        #expect(LogseqContentMode.outliner.toggled == .logseq)
        #expect(LogseqContentMode(rawValue: "unknown") == nil)
    }

    @Test func regularPagesAlwaysUseOutlinerPresentation() {
        #expect(LogseqContentMode.logseq.presentationMode(hasSelectedPage: true) == .outliner)
        #expect(LogseqContentMode.outliner.presentationMode(hasSelectedPage: true) == .outliner)
        #expect(!LogseqContentMode.supportsModeSwitch(hasSelectedPage: true))
    }

    @Test func journalsKeepLogseqAndOutlinerModes() {
        #expect(LogseqContentMode.logseq.presentationMode(hasSelectedPage: false) == .logseq)
        #expect(LogseqContentMode.outliner.presentationMode(hasSelectedPage: false) == .outliner)
        #expect(LogseqContentMode.supportsModeSwitch(hasSelectedPage: false))
    }

    @Test @MainActor func deleteBlockUsesOperationIdentityAndAuthoritativeCursor() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return outlineSnapshotJSON(blocks: [], appliedServerT: 48192)
        }
        let block = LogseqBlock(
            uuid: "delete-me", title: "Delete me", pageId: "page",
            parentId: "page", createdAt: 1, updatedAt: 1, syncStatus: "synced"
        )

        store.refresh()
        try await waitUntil { store.snapshot.appliedServerT == 48192 }
        store.delete(block: block)
        try await waitUntil { recorder.all.contains { $0.contains("deleteBlock") } }

        let request = try #require(recorder.all.first { $0.contains("deleteBlock") })
        #expect(request.contains("\\\"uuid\\\":\\\"delete-me\\\""))
        #expect(request.contains("\\\"expectedServerT\\\":48192"))
        #expect(request.contains("\\\"operationId\\\":"))
    }

    @Test @MainActor func deleteBlockIsRejectedWithoutAuthoritativeCursor() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return outlineSnapshotJSON(blocks: [], appliedServerT: nil)
        }
        let block = LogseqBlock(
            uuid: "delete-me", title: "Delete me", pageId: "page",
            parentId: "page", createdAt: 1, updatedAt: 1, syncStatus: "synced"
        )

        store.delete(block: block)
        try await Task.sleep(for: .milliseconds(50))

        #expect(!recorder.all.contains { $0.contains("deleteBlock") })
        #expect(store.lastError?.code == "delete_requires_server_cursor")
    }


    @Test @MainActor func outlinerEventsAreSerializedThroughTheCoreReducer() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return outlineSnapshotJSON(blocks: [], appliedServerT: 51)
        }

        store.outlinerEvent(LogseqOutlinerEvent(type: "tapBlock", uuid: "source"))
        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "hello", caretUTF16Offset: 5
        ))
        try await waitUntil(timeout: 2.0) {
            recorder.all.filter { $0.contains("outlinerEvent") }.count == 2
        }
        let events = recorder.all.filter { $0.contains("outlinerEvent") }
        let first = try #require(events.first)
        let last = try #require(events.last)
        #expect(first.contains("tapBlock"))
        #expect(last.contains("textChanged"))
    }

    @Test @MainActor func outlinerEventsDoNotBlockTheMainActorWhenCoreIsSlow() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("outlinerEvent") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            return outlineSnapshotJSON(blocks: [], appliedServerT: 51)
        }

        let start = Date()
        store.outlinerEvent(LogseqOutlinerEvent(type: "tapBlock", uuid: "source"))
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.1)
        try await waitUntil {
            recorder.all.contains { $0.contains("outlinerEvent") }
        }
    }

    @Test @MainActor func burstyOutlinerMutationsScheduleOneTrailingPendingSync() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"beginPendingSync\"") {
                return """
                {"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],\
                "selectedBlock":null,"pendingSyncRequest":null,\
                "hasPendingSemanticOperations":true,"isPendingSyncPatch":true},"error":null}
                """
            }
            let hasPending = request.contains("\"type\":\"saveEditing\"")
            return """
            {"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],\
            "selectedBlock":null,"outlinerRows":[],"hasPendingSemanticOperations":\(hasPending),\
            "isOutlinerPatch":true},"error":null}
            """
        }

        store.outlinerEvent(LogseqOutlinerEvent(type: "toolbar", action: "indent"))
        store.outlinerEvent(LogseqOutlinerEvent(type: "toolbar", action: "outdent"))
        store.outlinerEvent(LogseqOutlinerEvent(type: "toolbar", action: "indent"))
        try await waitUntil {
            recorder.all.filter { $0.contains("\"action\":\"outlinerEvent\"") }.count == 3
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!recorder.all.contains { $0.contains("\"action\":\"beginPendingSync\"") })

        try await waitUntil {
            recorder.all.filter { $0.contains("\"action\":\"beginPendingSync\"") }.count == 1
        }
    }

    @Test @MainActor func outlinerTypingResetsTheOneSecondServerAutosaveTimer() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("\"action\":\"beginPendingSync\"") {
                return """
                {"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],\
                "selectedBlock":null,"pendingSyncRequest":null,\
                "hasPendingSemanticOperations":true,"isPendingSyncPatch":true},"error":null}
                """
            }
            return """
            {"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],\
            "selectedBlock":null,"outlinerRows":[],"hasPendingSemanticOperations":true,\
            "isOutlinerPatch":true},"error":null}
            """
        }

        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "first", caretUTF16Offset: 5
        ))
        try await waitUntil {
            recorder.all.contains { $0.contains("\"title\":\"first\"") }
        }
        try await Task.sleep(for: .milliseconds(700))
        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "second", caretUTF16Offset: 6
        ))
        try await waitUntil {
            recorder.all.contains { $0.contains("\"title\":\"second\"") }
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!recorder.all.contains { $0.contains("\"type\":\"saveEditing\"") })
        #expect(!recorder.all.contains { $0.contains("\"action\":\"beginPendingSync\"") })

        try await waitUntil(timeout: 2.0) {
            recorder.all.filter { $0.contains("\"type\":\"saveEditing\"") }.count == 1
        }
        try await waitUntil(timeout: 2.0) {
            recorder.all.filter { $0.contains("\"action\":\"beginPendingSync\"") }.count == 1
        }
    }

    @Test @MainActor func outlinerAutocompleteSuspendsAutosaveUntilCompletion() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            let autocomplete = request.contains("\\\"type\\\":\\\"textChanged\\\"")
                ? #"{"kind":"tag","query":"","startUTF16Offset":0,"endUTF16Offset":1}"#
                : "null"
            return """
            {"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],\
            "selectedBlock":null,"outlinerRows":[],\
            "outlinerState":{"editing":{"uuid":"source","title":"#",\
            "caretUTF16Offset":1},"selectedBlockIds":[],"autocomplete":\(autocomplete),\
            "collapsedBlockIds":[],"zoomedBlockIds":[]},\
            "hasPendingSemanticOperations":false,"isOutlinerPatch":true},"error":null}
            """
        }

        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "#", caretUTF16Offset: 1
        ))
        try await waitUntil {
            store.snapshot.outlinerState.autocomplete?.kind == .tag
        }
        try await Task.sleep(for: .milliseconds(1_150))

        #expect(!recorder.all.contains { $0.contains("\"type\":\"saveEditing\"") })
    }

    @Test @MainActor func boundedOutlinerPatchPreservesTheLongPageProjection() async throws {
        let block = outlineBlockJSON(
            uuid: "source", parentID: "page", order: "a0", createdAt: 1
        )
        let store = LogseqStore { request in
            if request.contains("outlinerEvent") {
                return """
                {"apiVersion":1,"ok":true,"result":{"revision":1,"query":"",\
                "blocks":[],"selectedBlock":null,"isSearching":false,\
                "outlinerState":{"editing":{"uuid":"source","title":"source",\
                "caretUTF16Offset":6},"selectedBlockIds":[],"autocomplete":null,\
                "collapsedBlockIds":[],"zoomedBlockIds":[]},\
                "outlinerRows":[],"isOutlinerPatch":true},"error":null}
                """
            }
            return outlineSnapshotJSON(blocks: [block], appliedServerT: 51)
        }

        store.refresh()
        try await waitUntil { store.snapshot.blocks.count == 1 }
        store.outlinerEvent(LogseqOutlinerEvent(type: "tapBlock", uuid: "source"))
        try await waitUntil { store.snapshot.outlinerState.editing?.uuid == "source" }

        #expect(store.snapshot.blocks.map(\.uuid) == ["source"])
        #expect(store.snapshot.outlinerState.editing?.title == "source")
    }

    @Test @MainActor func boundedTitlePatchUpdatesOnlyTheChangedLongPageRow() async throws {
        let first = outlineBlockJSON(
            uuid: "first", parentID: "page", order: "a0", createdAt: 1
        )
        let second = outlineBlockJSON(
            uuid: "second", parentID: "page", order: "a1", createdAt: 2
        )
        let store = LogseqStore { request in
            if request.contains("outlinerEvent") {
                return """
                {"apiVersion":1,"ok":true,"result":{"revision":1,"query":"",\
                "blocks":[{"uuid":"first","title":"After",\
                "pageId":"page","parentId":"page","order":"a0","createdAt":1,\
                "updatedAt":2,"syncStatus":"pending","tags":[],"references":[]}],\
                "selectedBlock":null,"isSearching":false,\
                "outlinerState":{"editing":null,"selectedBlockIds":[],\
                "autocomplete":null,"collapsedBlockIds":[],"zoomedBlockIds":[]},\
                "outlinerRows":[],"outlinerRowSplices":[],\
                "isOutlinerPatch":true},"error":null}
                """
            }
            return outlineSnapshotJSON(blocks: [first, second], appliedServerT: 51)
        }

        store.refresh()
        try await waitUntil { store.snapshot.blocks.count == 2 }
        store.outlinerEvent(LogseqOutlinerEvent(type: "toolbar", action: "hideKeyboard"))
        try await waitUntil { store.snapshot.blocks.first?.title == "After" }

        #expect(store.snapshot.blocks.map(\.title) == ["After", "second"])
        #expect(store.snapshot.outlinerRows.map(\.block.title) == ["After", "second"])
    }

    @Test @MainActor func structuralPatchInsertsOneRowWithoutReplacingTheLongPage() async throws {
        let first = outlineBlockJSON(
            uuid: "first", parentID: "page", order: "a0", createdAt: 1
        )
        let second = outlineBlockJSON(
            uuid: "second", parentID: "page", order: "a2", createdAt: 2
        )
        let inserted = """
        {"uuid":"inserted","title":"inserted","pageId":"page","parentId":"page",\
        "order":"a1","createdAt":3,"updatedAt":3,"syncStatus":"pending",\
        "tags":[],"references":[]}
        """
        let store = LogseqStore { request in
            if request.contains("outlinerEvent") {
                return """
                {"apiVersion":1,"ok":true,"result":{"revision":1,"query":"",\
                "blocks":[\(inserted)],"deletedBlockIds":[],"selectedBlock":null,\
                "outlinerState":{"editing":null,"selectedBlockIds":[],\
                "autocomplete":null,"collapsedBlockIds":[],"zoomedBlockIds":[]},\
                "outlinerRows":[],"outlinerRowSplices":[{"start":1,"deleteCount":0,\
                "rows":[{"block":\(inserted),"depth":0,"hasChildren":false,\
                "isCollapsed":false}]}],"isOutlinerPatch":true},"error":null}
                """
            }
            return outlineSnapshotJSON(blocks: [first, second], appliedServerT: 51)
        }

        store.refresh()
        try await waitUntil { store.snapshot.outlinerRows.count == 2 }
        store.outlinerEvent(LogseqOutlinerEvent(type: "returnPressed"))
        try await waitUntil { store.snapshot.outlinerRows.count == 3 }

        #expect(store.snapshot.blocks.map(\.uuid) == ["first", "second", "inserted"])
        #expect(store.snapshot.outlinerRows.map(\.block.uuid) == ["first", "inserted", "second"])
    }

    @Test @MainActor func anchoredJournalSplitPreservesUnrelatedRowsAndSubtreeOrder() async throws {
        let source = outlineBlockJSON(
            uuid: "source", parentID: "today", order: "a0", createdAt: 1
        )
        let child = outlineBlockJSON(
            uuid: "child", parentID: "source", order: "a0", createdAt: 2
        )
        let otherJournal = outlineBlockJSON(
            uuid: "other-journal", parentID: "other", order: "a0", createdAt: 3
        )
        let inserted = """
        {"uuid":"inserted","title":"inserted","pageId":"today","parentId":"today",\
        "order":"a1","createdAt":4,"updatedAt":4,"syncStatus":"pending",\
        "tags":[],"references":[]}
        """
        let store = LogseqStore { request in
            if request.contains("outlinerEvent") {
                return """
                {"apiVersion":1,"ok":true,"result":{"revision":1,"query":"",\
                "blocks":[\(inserted)],"deletedBlockIds":[],"selectedBlock":null,\
                "outlinerState":{"editing":{"uuid":"inserted","title":"inserted",\
                "caretUTF16Offset":0},"selectedBlockIds":[],"autocomplete":null,\
                "collapsedBlockIds":[],"zoomedBlockIds":[]},\
                "outlinerRows":[],"outlinerRowSplices":[{"afterBlockId":"child",\
                "deleteCount":0,"rows":[{"block":\(inserted),"depth":0,\
                "hasChildren":false,"isCollapsed":false}]}],\
                "isOutlinerPatch":true},"error":null}
                """
            }
            return outlineSnapshotJSON(
                blocks: [source, child, otherJournal],
                appliedServerT: 51
            )
        }

        store.refresh()
        try await waitUntil { store.snapshot.outlinerRows.count == 3 }
        store.outlinerEvent(LogseqOutlinerEvent(type: "returnPressed"))
        try await waitUntil { store.snapshot.outlinerRows.count == 4 }

        #expect(store.snapshot.outlinerRows.map(\.block.uuid) == [
            "source", "child", "inserted", "other-journal",
        ])
    }

    @Test @MainActor func anchoredPatchUsesTheVisibleBeforeAnchorWithoutDuplicatingRows() async throws {
        let source = outlineBlockJSON(
            uuid: "source", title: "Before", parentID: "today", order: "a0", createdAt: 1
        )
        let otherJournal = outlineBlockJSON(
            uuid: "other-journal", parentID: "other", order: "a0", createdAt: 2
        )
        let updatedSource = outlineBlockJSON(
            uuid: "source", title: "After", parentID: "today", order: "a0", createdAt: 1
        )
        let inserted = outlineBlockJSON(
            uuid: "inserted", parentID: "today", order: "a1", createdAt: 3
        )
        let store = LogseqStore { request in
            if request.contains("outlinerEvent") {
                return """
                {"apiVersion":1,"ok":true,"result":{"revision":1,"query":"",\
                "blocks":[\(updatedSource),\(inserted)],"deletedBlockIds":[],\
                "selectedBlock":null,"outlinerState":{"editing":{"uuid":"inserted",\
                "title":"","caretUTF16Offset":0},"selectedBlockIds":[],\
                "autocomplete":null,"collapsedBlockIds":[],"zoomedBlockIds":[]},\
                "outlinerRows":[],"outlinerRowSplices":[{"afterBlockId":"not-loaded",\
                "beforeBlockId":"source","deleteCount":1,"rows":[\
                {"block":\(updatedSource),"depth":0,"hasChildren":false,"isCollapsed":false},\
                {"block":\(inserted),"depth":0,"hasChildren":false,"isCollapsed":false}]}],\
                "isOutlinerPatch":true},"error":null}
                """
            }
            return outlineSnapshotJSON(blocks: [source, otherJournal], appliedServerT: 51)
        }

        store.refresh()
        try await waitUntil { store.snapshot.outlinerRows.count == 2 }
        store.outlinerEvent(LogseqOutlinerEvent(type: "returnPressed"))
        try await waitUntil { store.snapshot.outlinerRows.count == 3 }

        #expect(store.snapshot.outlinerRows.map(\.block.uuid) == [
            "source", "inserted", "other-journal",
        ])
        #expect(Set(store.snapshot.outlinerRows.map(\.block.uuid)).count == 3)
        #expect(store.snapshot.outlinerRows.first?.block.title == "After")
    }

    @Test @MainActor func structuralPatchDeletesOnlyTheAffectedRowRange() async throws {
        let first = outlineBlockJSON(
            uuid: "first", parentID: "page", order: "a0", createdAt: 1
        )
        let child = outlineBlockJSON(
            uuid: "child", parentID: "first", order: "a0", createdAt: 2
        )
        let second = outlineBlockJSON(
            uuid: "second", parentID: "page", order: "a1", createdAt: 3
        )
        let store = LogseqStore { request in
            if request.contains("outlinerEvent") {
                return """
                {"apiVersion":1,"ok":true,"result":{"revision":1,"query":"",\
                "blocks":[],"deletedBlockIds":["first","child"],"selectedBlock":null,\
                "outlinerState":{"editing":null,"selectedBlockIds":[],\
                "autocomplete":null,"collapsedBlockIds":[],"zoomedBlockIds":[]},\
                "outlinerRows":[],"outlinerRowSplices":[{"start":0,"deleteCount":2,\
                "rows":[]}],"isOutlinerPatch":true},"error":null}
                """
            }
            return outlineSnapshotJSON(blocks: [first, child, second], appliedServerT: 51)
        }

        store.refresh()
        try await waitUntil { store.snapshot.outlinerRows.count == 3 }
        store.outlinerEvent(LogseqOutlinerEvent(type: "confirmDelete"))
        try await waitUntil { store.snapshot.outlinerRows.count == 1 }

        #expect(store.snapshot.blocks.map(\.uuid) == ["second"])
        #expect(store.snapshot.outlinerRows.map(\.block.uuid) == ["second"])
    }

    @Test @MainActor func supersededTypingProjectionDoesNotOverwriteTheEditor() async throws {
        let store = LogseqStore { request in
            if request.contains("old") {
                Thread.sleep(forTimeInterval: 0.05)
                return outlinerSnapshotJSON(revision: 10, title: "old")
            }
            Thread.sleep(forTimeInterval: 0.20)
            return outlinerSnapshotJSON(revision: 20, title: "new")
        }

        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "old", caretUTF16Offset: 3
        ))
        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "new", caretUTF16Offset: 3
        ))
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.snapshot.revision == 0)
        try await waitUntil(timeout: 2.0) { store.snapshot.revision == 20 }
        #expect(store.snapshot.outlinerState.editing?.title == "new")
    }

    @Test @MainActor func rapidOutlinerTypingCoalescesToTheLatestTransientEvent() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return outlinerSnapshotJSON(revision: 1, title: "new")
        }

        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "n", caretUTF16Offset: 1
        ))
        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "ne", caretUTF16Offset: 2
        ))
        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "new", caretUTF16Offset: 3
        ))

        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.all.allSatisfy { !$0.contains("outlinerEvent") })
        try await waitUntil {
            recorder.all.contains { $0.contains("outlinerEvent") }
        }
        let events = recorder.all.filter { $0.contains("outlinerEvent") }
        #expect(events.count == 1)
        #expect(events[0].contains("new"))
        #expect(!events[0].contains("\\\"title\\\":\\\"ne\\\""))
    }

    @Test @MainActor func structuralOutlinerEventFlushesLatestTypingFirst() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return outlineSnapshotJSON(blocks: [], appliedServerT: 51)
        }

        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "latest", caretUTF16Offset: 6
        ))
        store.outlinerEvent(LogseqOutlinerEvent(type: "returnPressed"))

        try await waitUntil {
            recorder.all.filter { $0.contains("outlinerEvent") }.count == 2
        }
        let events = recorder.all.filter { $0.contains("outlinerEvent") }
        #expect(events[0].contains("textChanged"))
        #expect(events[0].contains("latest"))
        #expect(events[1].contains("returnPressed"))
    }

    @Test @MainActor func taskToolbarActionIsNotDelayedByQueuedTyping() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return outlineSnapshotJSON(blocks: [], appliedServerT: 51)
        }

        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "latest", caretUTF16Offset: 6
        ))
        store.outlinerEvent(LogseqOutlinerEvent(type: "toolbar", action: "task"))

        try await waitUntil {
            recorder.all.filter { $0.contains("outlinerEvent") }.count == 2
        }
        let events = recorder.all.filter { $0.contains("outlinerEvent") }
        #expect(events[0].contains("\"action\":\"task\""))
        #expect(events[1].contains("textChanged"))
        #expect(events[1].contains("latest"))
    }

    @Test @MainActor func commandFlushCannotBeSupersededByALateCaretEvent() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("tapBlock") {
                Thread.sleep(forTimeInterval: 0.30)
            }
            return outlineSnapshotJSON(blocks: [], appliedServerT: 51)
        }

        store.outlinerEvent(LogseqOutlinerEvent(type: "tapBlock", uuid: "source"))
        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "child title", caretUTF16Offset: 11
        ))
        store.outlinerEvent(LogseqOutlinerEvent(type: "toolbar", action: "indent"))
        store.outlinerEvent(LogseqOutlinerEvent(type: "caretMoved", caretUTF16Offset: 11))

        try await waitUntil(timeout: 2.0) {
            recorder.all.contains { $0.contains("indent") }
        }
        let events = recorder.all.filter { $0.contains("outlinerEvent") }
        #expect(events.contains { $0.contains("textChanged") && $0.contains("child title") })
        let textIndex = try #require(events.firstIndex { $0.contains("textChanged") })
        let commandIndex = try #require(events.firstIndex { $0.contains("indent") })
        #expect(textIndex < commandIndex)
    }

    @Test @MainActor func hideKeyboardCannotDropTypingAlreadyQueuedBehindCoreWork() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("tapBlock") {
                Thread.sleep(forTimeInterval: 0.30)
            }
            return outlineSnapshotJSON(blocks: [], appliedServerT: 51)
        }

        store.outlinerEvent(LogseqOutlinerEvent(type: "tapBlock", uuid: "source"))
        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "must be saved", caretUTF16Offset: 13
        ))
        try await Task.sleep(for: .milliseconds(100))
        store.outlinerEvent(LogseqOutlinerEvent(type: "toolbar", action: "hideKeyboard"))

        try await waitUntil(timeout: 2.0) {
            recorder.all.contains { $0.contains("hideKeyboard") }
        }
        let events = recorder.all.filter { $0.contains("outlinerEvent") }
        let textIndex = try #require(events.firstIndex {
            $0.contains("textChanged") && $0.contains("must be saved")
        })
        let hideIndex = try #require(events.firstIndex { $0.contains("hideKeyboard") })
        #expect(textIndex < hideIndex)
    }

    @Test @MainActor func atomicReturnDropsPendingTypingAndUsesOneCoreRequest() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return outlineSnapshotJSON(blocks: [], appliedServerT: 51)
        }

        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "stale", caretUTF16Offset: 5
        ))
        store.outlinerEvent(LogseqOutlinerEvent(
            type: "returnPressed", title: "final", caretUTF16Offset: 5
        ))

        try await waitUntil {
            recorder.all.filter { $0.contains("outlinerEvent") }.count == 1
        }
        let event = try #require(recorder.all.first { $0.contains("outlinerEvent") })
        #expect(event.contains("returnPressed"))
        #expect(event.contains("final"))
        #expect(!event.contains("textChanged"))
        #expect(!event.contains("stale"))
    }

    @Test @MainActor func atomicBackspaceDropsPendingTypingAndUsesOneCoreRequest() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            return outlineSnapshotJSON(blocks: [], appliedServerT: 51)
        }

        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "stale", caretUTF16Offset: 5
        ))
        store.outlinerEvent(LogseqOutlinerEvent(
            type: "backspacePressed", title: "final", selectionLength: 0
        ))

        try await waitUntil {
            recorder.all.filter { $0.contains("outlinerEvent") }.count == 1
        }
        let event = try #require(recorder.all.first { $0.contains("outlinerEvent") })
        #expect(event.contains("backspacePressed"))
        #expect(event.contains("final"))
        #expect(!event.contains("textChanged"))
        #expect(!event.contains("stale"))
    }

    @Test @MainActor func repeatedBoundaryBackspaceRebasesAcrossTheLatestEmptyBlocks() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("backspacePressed") {
                let count = recorder.all.filter { $0.contains("backspacePressed") }.count
                return outlinerEditingSnapshotJSON(
                    revision: count,
                    uuid: count == 1 ? "empty-2" : "empty-1",
                    title: count == 1 ? "second" : "first"
                )
            }
            return outlineSnapshotJSON(blocks: [], appliedServerT: 51)
        }

        let boundaryBackspace = LogseqOutlinerEvent(
            type: "backspacePressed",
            uuid: "source",
            title: "",
            selectionLength: 0
        )
        store.outlinerEvent(boundaryBackspace)
        store.outlinerEvent(boundaryBackspace)
        store.outlinerEvent(boundaryBackspace)

        try await waitUntil(timeout: 2.0) {
            recorder.all.filter { $0.contains("backspacePressed") }.count == 3
        }
        let mergeEvents = recorder.all.filter { $0.contains("backspacePressed") }
        #expect(mergeEvents.count == 3)
        #expect(mergeEvents[0].contains("\\\"uuid\\\":\\\"source\\\""))
        #expect(mergeEvents[1].contains("\\\"uuid\\\":\\\"empty-2\\\""))
        #expect(mergeEvents[2].contains("\\\"uuid\\\":\\\"empty-1\\\""))
        #expect(mergeEvents[1].contains("\\\"title\\\":\\\"second\\\""))
        #expect(mergeEvents[2].contains("\\\"title\\\":\\\"first\\\""))
    }

    @Test @MainActor func atomicReturnSkipsAQueuedSupersededTypingRequest() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("tapBlock") {
                Thread.sleep(forTimeInterval: 1.40)
            }
            return outlineSnapshotJSON(blocks: [], appliedServerT: 51)
        }

        store.outlinerEvent(LogseqOutlinerEvent(type: "tapBlock", uuid: "source"))
        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "superseded", caretUTF16Offset: 10
        ))
        try await Task.sleep(for: .milliseconds(1_100))
        store.outlinerEvent(LogseqOutlinerEvent(
            type: "returnPressed", title: "final", caretUTF16Offset: 5
        ))

        try await waitUntil {
            recorder.all.contains { $0.contains("returnPressed") }
        }
        let events = recorder.all.filter { $0.contains("outlinerEvent") }
        #expect(events.count == 2)
        #expect(events[0].contains("tapBlock"))
        #expect(events[1].contains("returnPressed"))
        #expect(!events.contains { $0.contains("superseded") })
    }

    @Test @MainActor func atomicBackspaceSkipsAQueuedSupersededTypingRequest() async throws {
        let recorder = RequestRecorder()
        let store = LogseqStore { request in
            recorder.append(request)
            if request.contains("tapBlock") {
                Thread.sleep(forTimeInterval: 1.40)
            }
            return outlineSnapshotJSON(blocks: [], appliedServerT: 51)
        }

        store.outlinerEvent(LogseqOutlinerEvent(type: "tapBlock", uuid: "source"))
        store.outlinerEvent(LogseqOutlinerEvent(
            type: "textChanged", title: "superseded", caretUTF16Offset: 10
        ))
        try await Task.sleep(for: .milliseconds(1_100))
        store.outlinerEvent(LogseqOutlinerEvent(
            type: "backspacePressed", title: "final", selectionLength: 0
        ))

        try await waitUntil {
            recorder.all.contains { $0.contains("backspacePressed") }
        }
        let events = recorder.all.filter { $0.contains("outlinerEvent") }
        #expect(events.count == 2)
        #expect(events[0].contains("tapBlock"))
        #expect(events[1].contains("backspacePressed"))
        #expect(!events.contains { $0.contains("superseded") })
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
        let query = action == "searchNodes" ? (decoded?.params.payload ?? "") : ""
        return """
        {
          "apiVersion": 1,
          "ok": true,
          "result": {
            "revision": 1,
            "searchQuery": "\(query)",
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

private struct TestSendPayload: Decodable {
    let uuid: String
}

private func latestSendUUID(in recorder: RequestRecorder) -> String? {
    for request in recorder.all.reversed() {
        guard request.contains("\"action\":\"send\"") else { continue }
        if let uuid = extractSendUUID(from: request) {
            return uuid
        }
    }
    return nil
}

private func extractSendUUID(from request: String) -> String? {
    let escapedMarker = "\\\"uuid\\\":\\\""
    if let uuid = extractValue(from: request, after: escapedMarker, before: "\\\"") {
        return uuid
    }

    let marker = "\"uuid\":\""
    return extractValue(from: request, after: marker, before: "\"")
}

private func extractValue(from text: String, after marker: String, before terminator: String) -> String? {
    let parts = text.components(separatedBy: marker)
    guard parts.count > 1 else {
        return nil
    }
    let tailParts = parts[1].components(separatedBy: terminator)
    guard let value = tailParts.first, !value.isEmpty else {
        return nil
    }
    return value
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
    @Test func synchronousAndAsynchronousCallsUseTheSameSerialThread() async {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)

        let first = Task {
            await LogseqCoreExecutor.shared.call(
                { _ in
                    firstStarted.signal()
                    releaseFirst.wait()
                    return "first"
                },
                requestJSON: "first"
            )
        }
        #expect(firstStarted.wait(timeout: .now() + 1) == .success)

        let second = Task.detached {
            LogseqCoreExecutor.shared.callSync(
                { _ in
                    secondStarted.signal()
                    return "second"
                },
                requestJSON: "second"
            )
        }
        #expect(secondStarted.wait(timeout: .now() + 0.05) == .timedOut)

        releaseFirst.signal()
        #expect(await first.value == "first")
        #expect(await second.value == "second")
        #expect(secondStarted.wait(timeout: .now() + 1) == .success)
    }
}
