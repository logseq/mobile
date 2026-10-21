import Foundation
import Observation
#if !os(Android)
import OSLog
#endif
import LogseqCoreABI

private struct LogseqModelLogger {
    #if !os(Android)
    private let logger = Logger(subsystem: "logseq.app.model", category: "LogseqModel")
    #endif

    func info(_ message: String) {
        LogseqRuntimeLog.shared.append(level: .info, source: .core, message: message)
        #if os(Android)
        print(message)
        #else
        // notice so the line survives the sim's unified-log filtering (info
        // is dropped from device-simulator.log captures).
        logger.notice("\(message, privacy: .public)")
        #endif
    }

    func error(_ message: String) {
        LogseqRuntimeLog.shared.append(level: .error, source: .core, message: message)
        #if os(Android)
        print(message)
        #else
        logger.error("\(message, privacy: .public)")
        #endif
    }
}

private let logger = LogseqModelLogger()

public final class LogseqCore {
    nonisolated(unsafe) public static let shared = LogseqCore()

    private init() {
    }

    private func invokeCore(_ operation: @escaping @Sendable () -> String) -> String {
        LogseqCoreExecutor.shared.callSync(
            { _ in operation() },
            requestJSON: "",
            priority: .interaction
        )
    }

    public func initialize() {
        #if LOGSEQ_CORE
        _ = invokeCore { "" }
        #endif
    }

    public nonisolated static func performUIAsync(
        _ operation: @escaping @Sendable () -> String
    ) async -> String {
        await LogseqCoreExecutor.shared.call(
            { _ in operation() }, requestJSON: "", priority: .interaction
        )
    }

    public func logseq_call(_ request: String) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_call(request))
        }
        #else
        return
            """
            {
              "apiVersion": 1,
              "ok": false,
              "result": null,
              "error": {
                "code": "native_core_unlinked",
                "message": "Build with the OCaml DataScript core and LOGSEQ_CORE"
              }
            }
            """
        #endif
    }

    public nonisolated static func callAsync(_ request: LogseqRPCRequest) async -> String {
        guard let data = try? JSONEncoder().encode(request),
              let requestJSON = String(data: data, encoding: .utf8) else {
            return ""
        }
        return await LogseqCoreExecutor.shared.call(
            { request in LogseqCore.shared.logseq_call(request) },
            requestJSON: requestJSON,
            priority: .interaction
        )
    }

    public func logseq_lui_initialize(
        _ platformCode: Int,
        _ hostCode: Int,
        _ authenticationCode: Int
    ) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_initialize(
                Int32(platformCode),
                Int32(hostCode),
                Int32(authenticationCode)
            ))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_press(_ node: Int) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_press(Int64(node)))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_appear(_ node: Int) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_appear(Int64(node)))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_long_press(_ node: Int) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_long_press(Int64(node)))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_text_changed(
        _ node: Int,
        _ text: String
    ) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_text_changed(
                Int64(node),
                text
            ))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_submit(_ node: Int) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_submit(Int64(node)))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_toggle_changed(
        _ node: Int,
        _ checked: Bool
    ) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_toggle_changed(
                Int64(node),
                checked ? 1 : 0
            ))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_change(_ node: Int) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_change(Int64(node)))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_value_changed(
        _ node: Int,
        _ value: Double
    ) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_value_changed(
                Int64(node),
                value
            ))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_dismiss(_ node: Int) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_dismiss(Int64(node)))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_double_press(_ node: Int) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_double_press(Int64(node)))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_extension_event(
        _ node: Int,
        _ identifier: String,
        _ name: String,
        _ text: String,
        _ value: Int
    ) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_extension_event(
                Int64(node),
                identifier,
                name,
                text,
                Int64(value)
            ))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_picked(_ node: Int, _ payload: String) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_picked(
                Int64(node),
                payload
            ))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_visible_range(
        _ node: Int,
        _ first: Int,
        _ last: Int
    ) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_visible_range(
                Int64(node),
                Int64(first),
                Int64(last)
            ))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_scroll_completed(
        _ node: Int,
        _ token: Int,
        _ outcome: String
    ) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_scroll_completed(
                Int64(node),
                Int64(token),
                outcome
            ))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_dispose() -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_dispose())
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_take_effect() -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_take_effect())
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_resolve_effect(
        _ effectID: Int,
        _ succeeded: Bool,
        _ message: String
    ) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_resolve_effect(
                Int64(effectID),
                succeeded ? 1 : 0,
                message
            ))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_apply_snapshot(
        _ responseJSON: String
    ) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_apply_snapshot(
                responseJSON
            ))
        }
        #else
        return ""
        #endif
    }

    public func logseq_lui_apply_host_update(
        _ kind: String,
        _ payloadJSON: String
    ) -> String {
        #if LOGSEQ_CORE
        return invokeCore {
            String(cString: LogseqCoreABI.logseq_lui_apply_host_update(
                kind,
                payloadJSON
            ))
        }
        #else
        return ""
        #endif
    }
}

private struct LogseqPendingSyncCompletion: Encodable {
    let id: Int
    let status: Int?
    let body: String?
    let error: String?
}

private struct ConfigurePayload: Encodable {
    let baseUrl: String
    let graphId: String
    let token: String
}

private struct AddAssetPayload: Encodable {
    let uuid: String
    let title: String
    let now: Int64
    let assetType: String
    let assetSize: Int
    let assetChecksum: String
    let localPath: String
    let targetBlockId: String?
}

private struct ImportSnapshotPayload: Encodable {
    let graphId: String
    let activePath: String
    let checkpointPath: String
    let metadataBody: String
    let downloadPath: String
    let isEncrypted: Bool
    let forceSnapshot: Bool
    let generation: Int?
}

private struct OpenGraphPayload: Encodable {
    let graphId: String
    let activePath: String
    let checkpointPath: String
    let isEncrypted: Bool
    let forceSnapshot: Bool
    let allowSnapshotDownload: Bool
    let hasAccessToken: Bool
}

private struct CreateSyncGraphPayload: Encodable {
    let name: String
    let isEncrypted: Bool
    let password: String?
}

@MainActor @Observable public final class LogseqStore {
    public private(set) var snapshot = LogseqSnapshot(
        revision: 0,
        blocks: [],
        selectedBlock: nil,
        lastRefreshAt: nil,
        graphName: nil,
        relatedBlocks: nil
    )
    public private(set) var lastError: LogseqCoreError?
    public private(set) var syncError: LogseqCoreError?
    public private(set) var graphEventsRetryDelayMilliseconds = 0
    private var syncTransport: LogseqSyncTransport?
    public private(set) var isRefreshing = false
    @ObservationIgnored public var graphDownloadProgressChanged: (@MainActor (LogseqGraphDownloadProgress?) -> Void)?
    private var graphDownloadProgress: LogseqGraphDownloadProgress?
    private var graphDownloadGeneration = 0

    private func reportDownloadProgress(_ progress: LogseqGraphDownloadProgress?) {
        // Queued callbacks cannot move an importing graph back to the transfer phase.
        if let progress, progress.phase == "downloading",
           let current = graphDownloadProgress, current.graphId == progress.graphId,
           current.phase == "decoding" || current.phase == "importing" || current.phase == "opening" { return }
        guard progress != graphDownloadProgress else { return }
        graphDownloadProgress = progress
        graphDownloadProgressChanged?(progress)
    }

    private let callCore: @Sendable (String) -> String
    private let pendingTransport: @Sendable (LogseqPendingSyncRequest) async -> LogseqPendingSyncResult
    private let responseObserver: @MainActor (String) -> Void
    private var openedDatabasePath: String?
    public private(set) var graphSyncAllowed = false
    private var bootstrapPlan: LogseqBootstrapPlan?
    private var debugDatabaseRoute = "unopened"
    private var pendingSyncTask: Task<Void, Never>?
    private var pendingSyncRequested = false

    public convenience init(call: @escaping @Sendable (String) -> String) {
        self.init(call: call, responseObserver: { _ in })
    }

    public convenience init(
        call: @escaping @Sendable (String) -> String,
        responseObserver: @escaping @MainActor (String) -> Void
    ) {
        self.init(
            call: call,
            pendingTransport: { request in
                await LogseqPendingSyncHTTPTransport.send(request)
            },
            responseObserver: responseObserver
        )
    }

    public init(
        call: @escaping @Sendable (String) -> String,
        pendingTransport: @escaping @Sendable (LogseqPendingSyncRequest) async -> LogseqPendingSyncResult,
        responseObserver: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.callCore = call
        self.pendingTransport = pendingTransport
        self.responseObserver = responseObserver
    }

    public func open(path: String) {
        openedDatabasePath = path
        debugDatabaseRoute = "catalog:\(path)"
        #if DEBUG
        print("LOGSEQ_DB_ROUTE request=open route=\(debugDatabaseRoute)")
        logger.info("LOGSEQ_DB_ROUTE request=open route=\(debugDatabaseRoute)")
        #endif
        performAsync(LogseqRPCRequest(method: "open", params: LogseqRPCParams(action: nil, path: path)))
    }

    public func openAndWait(path: String) async {
        openedDatabasePath = path
        debugDatabaseRoute = "catalog:\(path)"
        #if DEBUG
        print("LOGSEQ_DB_ROUTE request=open_and_wait route=\(debugDatabaseRoute)")
        logger.info("LOGSEQ_DB_ROUTE request=open_and_wait route=\(debugDatabaseRoute)")
        #endif
        await performAsyncAndWait(
            LogseqRPCRequest(
                method: "open",
                params: LogseqRPCParams(action: nil, path: path)
            )
        )
    }

    public nonisolated static func callForLaunch(_ request: LogseqRPCRequest) -> String {
        guard let data = try? JSONEncoder().encode(request),
              let requestJSON = String(data: data, encoding: .utf8) else { return "" }
        return LogseqCore.shared.logseq_call(requestJSON)
    }

    public func applyLaunchResponse(
        _ responseJSON: String,
        actionName: String,
        databasePath: String
    ) {
        let startedAt = Date()
        openedDatabasePath = databasePath
        apply(responseJSON: responseJSON, actionName: actionName)
        if actionName == "openGraph", let graphID = snapshot.selectedGraphId {
            debugDatabaseRoute = "graph:\(graphID)"
            #if DEBUG
            print("LOGSEQ_DB_ROUTE launch_applied route=\(debugDatabaseRoute)")
            #endif
            // The first snapshot after openGraph ships an empty sidebar so
            // it stays off the launch critical path; fetch it right after
            // the journal renders.
            Task { [weak self] in
                await self?.dispatchRawAndWait("loadSidebar")
            }
        }
        let elapsedMilliseconds = Date().timeIntervalSince(startedAt) * 1_000
        print(
            "LOGSEQ_LAUNCH_APPLY_METRIC action=\(actionName) "
                + "bytes=\(responseJSON.utf8.count) "
                + "elapsed_ms=\(String(format: "%.3f", elapsedMilliseconds))"
        )
    }

    public func resetToCatalog(applyResponse: Bool = true) async {
        guard let openedDatabasePath else {
            lastError = LogseqCoreError(
                code: "database_not_open",
                message: "Open local storage before resetting the graph"
            )
            return
        }
        // When a caller issues several RPCs back-to-back (e.g. graph deletion:
        // catalog reset followed by configure), applying each response renders
        // intermediate tree states. Consecutive commits inside one SwiftUI
        // update window get replayed as a single coalesced collection batch,
        // which can double-apply a row delete and crash; suppressing the
        // intermediate apply collapses the transition into one commit.
        await performAsyncAndWait(
            LogseqRPCRequest(
                method: "open",
                params: LogseqRPCParams(action: nil, path: openedDatabasePath)
            ),
            shouldApply: { applyResponse }
        )
    }

    public func configure(
        baseURL: String, token: String, graphID: String? = nil,
        refreshAfterApply: Bool = true
    ) {
        let baseURL = Self.normalizedBaseURL(baseURL)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = encodePayload(
            ConfigurePayload(baseUrl: baseURL, graphId: graphID ?? "", token: token),
            action: "configure"
        ) else { return }
        performAsync(LogseqRPCRequest(method: "dispatch", params: LogseqRPCParams(action: "configure", payload: payload)), afterApply: {
            if refreshAfterApply {
                self.refreshSoon()
            }
        })
    }

    public func configureAndSelectGraph(
        baseURL: String, token: String, selectedGraphID: String?,
        refreshGraphCatalog: Bool = false
    ) async {
        let baseURL = Self.normalizedBaseURL(baseURL)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = encodePayload(
            ConfigurePayload(
                baseUrl: baseURL,
                graphId: selectedGraphID ?? "",
                token: token
            ),
            action: "configure"
        ) else { return }
        await performAsyncAndWait(
            LogseqRPCRequest(
                method: "dispatch",
                params: LogseqRPCParams(action: "configure", payload: payload)
            )
        )
        guard lastError == nil else { return }
        if let selectedGraphID {
            if refreshGraphCatalog && !token.isEmpty {
                await performAsyncAndWait(
                    LogseqRPCRequest(
                        method: "dispatch",
                        params: LogseqRPCParams(action: "refreshGraphCatalog")
                    )
                )
                guard
                    lastError == nil,
                    snapshot.graphs?.contains(where: { $0.id == selectedGraphID }) == true
                else { return }
            }
            if !token.isEmpty {
                syncPending()
            }
            return
        }
        await performAsyncAndWait(
            LogseqRPCRequest(method: "dispatch", params: LogseqRPCParams(action: "refresh"))
        )

    }

    @discardableResult public func selectGraphAndWait(_ graphID: String) async -> Bool {
        await performAsyncAndWait(
            LogseqRPCRequest(
                method: "dispatch",
                params: LogseqRPCParams(action: "selectGraph", payload: graphID)
            )
        )
        return lastError == nil && snapshot.selectedGraphId == graphID
    }

    public func createSyncGraph(name: String, isEncrypted: Bool, password: String? = nil) async -> Bool {
        guard let payload = encodePayload(
            CreateSyncGraphPayload(name: name, isEncrypted: isEncrypted, password: password),
            action: "createSyncGraph"
        ) else { return false }
        await dispatchRawAndWait("createSyncGraph", payload: payload)
        return lastError == nil
    }

    public func unlockGraph(_ password: String) async {
        await performAsyncAndWait(
            LogseqRPCRequest(
                method: "dispatch",
                params: LogseqRPCParams(action: "unlockGraph", payload: password)
            )
        )
    }

    public func bootstrapSelectedGraph(
        graphID: String, baseURL: String, accessToken: String, forceSnapshot: Bool = false,
        allowSnapshotDownload: Bool = true, isEncrypted: Bool = false
    ) async -> Bool {
        guard let openedDatabasePath else {
            lastError = LogseqCoreError(code: "database_not_open", message: "Open local storage before syncing")
            return false
        }
        do {
            let graphDirectory = try LogseqGraphLocalStorage.prepareDirectoryURL(
                databasePath: openedDatabasePath,
                graphID: graphID,
                graphName: snapshot.graphs?.first(where: { $0.id == graphID })?.name ?? "Graph"
            )
            try FileManager.default.createDirectory(at: graphDirectory, withIntermediateDirectories: true)
            let activeURL = graphDirectory.appendingPathComponent("graph.sqlite")
            let checkpointURL = graphDirectory.appendingPathComponent("sync.checkpoint")
            bootstrapPlan = nil
            graphSyncAllowed = false
            await dispatchEncodedAndWait("bootstrapGraph", OpenGraphPayload(
                graphId: graphID, activePath: activeURL.path, checkpointPath: checkpointURL.path,
                isEncrypted: isEncrypted, forceSnapshot: forceSnapshot, allowSnapshotDownload: allowSnapshotDownload,
                hasAccessToken: !accessToken.isEmpty
            ))
            guard lastError == nil, let plan = bootstrapPlan else { return false }
            if plan.kind != "download" { return true }

            let graphName = snapshot.graphs?.first(where: { $0.id == graphID })?.name ?? graphID
            let showsProgress = !forceSnapshot
            graphDownloadGeneration += 1
            let downloadGeneration = graphDownloadGeneration
            if showsProgress {
                #if LOGSEQ_CORE
                LogseqCoreABI.logseq_set_graph_import_progress_callback(receiveGraphImportProgress)
                #endif
                GraphImportProgressRelay.report = { [weak self] id, phase, completed, total in
                    guard let self, id == graphID, self.graphDownloadGeneration == downloadGeneration,
                          self.graphDownloadProgress?.phase == "importing" else { return }
                    self.reportDownloadProgress(LogseqGraphDownloadProgress(
                        graphId: id, graphName: graphName, phase: phase, completedItems: completed, totalItems: total
                    ))
                }
            }
            defer {
                if graphDownloadGeneration == downloadGeneration {
                    graphDownloadGeneration += 1
                    if showsProgress {
                        GraphImportProgressRelay.report = nil
                        reportDownloadProgress(nil)
                    }
                }
            }
            let coreCall = callCore
            let artifact = try await LogseqGraphSyncHTTP.downloadSnapshot(
                baseURL: baseURL,
                graphID: graphID,
                accessToken: accessToken,
                graphSchemaVersion: snapshot.graphs?.first(where: { $0.id == graphID })?.schemaVersion,
                progress: { [weak self] phase in
                    guard showsProgress else { return }
                    await self?.reportDownloadProgress(LogseqGraphDownloadProgress(
                        graphId: graphID, graphName: graphName, phase: phase,
                        completedItems: 0, totalItems: nil
                    ))
                },
                callCore: { request in
                    await LogseqCoreExecutor.shared.call(coreCall, requestJSON: request, priority: .maintenance)
                }
            )
            defer { try? FileManager.default.removeItem(atPath: artifact.filePath) }
            if showsProgress {
                reportDownloadProgress(LogseqGraphDownloadProgress(
                    graphId: graphID, graphName: graphName, phase: "importing",
                    completedItems: 0, totalItems: nil
                ))
            }
            let payload = ImportSnapshotPayload(
                graphId: graphID,
                activePath: activeURL.path,
                checkpointPath: checkpointURL.path,
                metadataBody: artifact.metadataBody,
                downloadPath: artifact.filePath,
                isEncrypted: plan.isEncrypted,
                forceSnapshot: forceSnapshot,
                generation: plan.generation
            )
            let payloadData = try JSONEncoder().encode(payload)
            guard let payloadString = String(data: payloadData, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            await performAsyncAndWait(
                LogseqRPCRequest(
                    method: "dispatch",
                    params: LogseqRPCParams(action: "importSnapshot", payload: payloadString)
                )
            )
            if lastError == nil {
                debugDatabaseRoute = "graph:\(graphID)"
            }
            return lastError == nil
        } catch {
            lastError = LogseqCoreError(code: "snapshot_download_failed", message: error.localizedDescription)
            return false
        }
    }

    public func runGraphEventsOnce(
        graphID: String, baseURL: String, accessToken: String,
        stopAfterFirstFrame: Bool = false
    ) async -> Bool {
        _ = baseURL
        graphEventsRetryDelayMilliseconds = 0
        syncTransport = nil
        await dispatchRawAndWait("beginSyncTransport", payload: "{}")
        guard let initial = syncTransport, initial.graphId == graphID else {
            syncError = lastError ?? LogseqCoreError(
                code: "websocket_connection_failed", message: "The core did not start the sync transport"
            )
            lastError = nil
            return false
        }
        let generation = initial.generation
        let startedAt = Date()
        var socket: URLSessionWebSocketTask?
        let cancellation = LogseqSocketCancellation()
        var commands = initial.commands
        var receivedFrame = false
        func event(_ type: String, body: String? = nil, message: String? = nil) async -> [LogseqSyncTransport.Command] {
            await dispatchEncodedAndWait("syncTransportEvent", LogseqSyncTransportEvent(
                generation: generation, graphId: graphID, type: type, body: body, message: message
            ))
            return syncTransport?.commands ?? []
        }
        do {
            return try await withTaskCancellationHandler {
                defer { socket?.cancel(with: .goingAway, reason: nil) }
                while !Task.isCancelled {
                    while !commands.isEmpty {
                        let command = commands.removeFirst()
                        switch command.type {
                        case "connect":
                            guard let address = command.url, let url = URL(string: address) else {
                                throw URLError(.badURL)
                            }
                            var request = URLRequest(url: url)
                            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                            let task = URLSession.shared.webSocketTask(with: request)
                            task.maximumMessageSize = 64 * 1024 * 1024
                            socket = task
                            cancellation.install(task)
                            task.resume()
                            commands += await event("opened")
                            syncError = nil
                        case "send":
                            guard let socket, let body = command.body else { throw URLError(.cannotParseResponse) }
                            try await socket.send(.string(body))
                        case "close":
                            socket?.cancel(with: .goingAway, reason: nil)
                            socket = nil
                        case "retry":
                            graphEventsRetryDelayMilliseconds = command.delayMs ?? 0
                            if let message = syncTransport?.error {
                                syncError = LogseqCoreError(code: "websocket_connection_failed", message: message)
                            }
                            return false
                        case "snapshot":
                            syncError = nil
                            return true
                        case "sync-pending":
                            syncPending()
                            if stopAfterFirstFrame && receivedFrame {
                                _ = await event("cancelled")
                                return false
                            }
                        default:
                            throw URLError(.cannotParseResponse)
                        }
                    }
                    guard let socket else { return false }
                    let message = try await socket.receive()
                    let text: String
                    switch message {
                    case .string(let value): text = value
                    case .data(let data):
                        guard let value = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
                        text = value
                    @unknown default: throw URLError(.cannotParseResponse)
                    }
                    receivedFrame = true
                    commands = await event("frame", body: text)
                }
                _ = await event("cancelled")
                return false
            } onCancel: {
                cancellation.cancel()
            }
        } catch {
            let transportError = error as NSError
            let closeCode = socket?.closeCode.rawValue ?? -1
            socket?.cancel(with: .goingAway, reason: nil)
            // A cancelled URLSession transport still needs recovery while its owning task is active.
            let cancelled = Task.isCancelled
            let commands = await event(cancelled ? "cancelled" : "failed",
                message: LogseqGraphWebSocketFailurePolicy.userFacingMessage(error))
            graphEventsRetryDelayMilliseconds = commands.first(where: { $0.type == "retry" })?.delayMs ?? 0
            logger.info("Logseq sync transport ended domain=\(transportError.domain) code=\(transportError.code) closeCode=\(closeCode) ownerCancelled=\(cancelled) lifetimeSeconds=\(Int(Date().timeIntervalSince(startedAt))) retryMs=\(graphEventsRetryDelayMilliseconds)")
            if !cancelled {
                syncError = LogseqCoreError(code: "websocket_connection_failed",
                    message: LogseqGraphWebSocketFailurePolicy.userFacingMessage(error))
            }
            lastError = nil
            return commands.contains(where: { $0.type == "snapshot" })
        }
    }

    public func completeSyncSnapshot(succeeded: Bool) async {
        guard let transport = syncTransport else { return }
        await dispatchEncodedAndWait("syncTransportEvent", LogseqSyncTransportEvent(
            generation: transport.generation, graphId: transport.graphId,
            type: succeeded ? "snapshot-applied" : "snapshot-failed",
            message: succeeded ? nil : (lastError?.message ?? "Snapshot refresh failed")
        ))
        graphEventsRetryDelayMilliseconds = syncTransport?.commands.first(where: { $0.type == "retry" })?.delayMs ?? 0
    }

    private func dispatchEncodedAndWait<T: Encodable>(
        _ action: String,
        _ value: T,
        shouldApply: (() -> Bool)? = nil
    ) async {
        guard let payload = encodePayload(value, action: action) else { return }
        await performAsyncAndWait(
            LogseqRPCRequest(
                method: "dispatch",
                params: LogseqRPCParams(action: action, payload: payload)
            ),
            shouldApply: shouldApply
        )
    }

    private func dispatchRawAndWait(_ action: String, payload: String? = nil) async {
        await performAsyncAndWait(
            LogseqRPCRequest(
                method: "dispatch",
                params: LogseqRPCParams(action: action, payload: payload)
            )
        )
    }

    private func refresh(afterApply: (() -> Void)?) {
        guard !isRefreshing else { return }
        isRefreshing = true
        performAsync(LogseqRPCRequest(method: "dispatch", params: LogseqRPCParams(action: "refresh")), afterApply: {
            self.isRefreshing = false
            afterApply?()
        })
    }

    public func refreshSoon() {
        Task {
            await Task.yield()
            refresh(afterApply: {
                if self.lastError == nil {
                    self.syncPending()
                }
            })
        }
    }

    public func captureSharedText(_ text: String, id: String) async -> Bool {
        await captureShared(text: text, title: nil, url: nil, id: id)
    }

    public func captureShared(text: String?, title: String?, url: String?, id: String) async -> Bool {
        struct Payload: Encodable { let uuid: String; let text: String?; let title: String?; let url: String? }
        lastError = nil
        await dispatchEncodedAndWait("captureShared", Payload(uuid: id, text: text, title: title, url: url))
        guard lastError == nil else { return false }
        syncPending()
        return true
    }

    public private(set) var deepLinkQuickAction: String?

    public func handleDeepLink(_ payload: String) async -> Bool {
        deepLinkQuickAction = nil
        await dispatchRawAndWait("handleDeepLink", payload: payload)
        guard lastError == nil else { return false }
        syncPending()
        return true
    }

    public func captureSharedAsset(
        id: String,
        title: String,
        assetType: String,
        assetSize: Int,
        assetChecksum: String,
        localPath: String
    ) async -> Bool {
        lastError = nil
        await dispatchEncodedAndWait(
            "addAsset",
            AddAssetPayload(
                uuid: id,
                title: title,
                now: Self.nowMilliseconds(),
                assetType: assetType,
                assetSize: assetSize,
                assetChecksum: assetChecksum,
                localPath: localPath,
                targetBlockId: nil
            )
        )
        guard lastError == nil else { return false }
        syncPending()
        return true
    }

    public func syncPending() {
        pendingSyncRequested = true
        guard pendingSyncTask == nil else { return }
        pendingSyncTask = Task { [weak self] in
            await self?.runPendingSyncPump()
            guard let self else { return }
            self.pendingSyncTask = nil
            if self.pendingSyncRequested {
                self.syncPending()
            }
        }
    }

    public func syncPendingForBackground() async {
        syncPending()
        guard let task = pendingSyncTask else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @MainActor public func runPendingSyncLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            syncPending()
        }
    }

    private func performAsync(
        _ request: LogseqRPCRequest,
        shouldApply: (() -> Bool)? = nil,
        afterApply: (() -> Void)? = nil
    ) {
        Task {
            await performAsyncAndWait(request, shouldApply: shouldApply)
            afterApply?()
        }
    }

    private func runPendingSyncPump() async {
        repeat {
            pendingSyncRequested = false
            await performAsyncAndWait(
                LogseqRPCRequest(
                    method: "dispatch",
                    params: LogseqRPCParams(action: "beginPendingSync")
                )
            )
            var pending = snapshot.pendingSyncRequest
            while let request = pending, !Task.isCancelled {
                if request.delayMs > 0 { try? await Task.sleep(for: .milliseconds(request.delayMs)) }
                guard !Task.isCancelled else { break }
                let result = await pendingTransport(request)
                if Task.isCancelled { break }
                let completion = LogseqPendingSyncCompletion(
                    id: request.id,
                    status: result.status,
                    body: result.body,
                    error: result.error
                )
                await dispatchEncodedAndWait("completePendingSync", completion)
                pending = snapshot.pendingSyncRequest
            }
            if Task.isCancelled {
                await dispatchRawAndWait("cancelPendingSync")
            }
        } while pendingSyncRequested && !Task.isCancelled
    }

    private func performAsyncAndWait(
        _ request: LogseqRPCRequest,
        shouldApply: (() -> Bool)? = nil
    ) async {
        let actionName = request.params.action ?? request.method
        guard let requestJSON = encode(request) else {
            return
        }
        #if DEBUG
        print("Logseq debug: async core action started \(actionName)")
        let coreStartedAt = Date()
        #endif
        logger.info("Core action started: \(actionName)")
        let responseJSON = await LogseqCoreExecutor.shared.call(
            callCore,
            requestJSON: requestJSON,
            priority: Self.corePriority(for: actionName)
        )
        #if DEBUG
        let coreMilliseconds = Date().timeIntervalSince(coreStartedAt) * 1_000
        print(
            "Logseq debug: async core action returned \(actionName) "
                + "coreMs=\(String(format: "%.2f", coreMilliseconds)) "
                + "requestBytes=\(requestJSON.utf8.count) responseBytes=\(responseJSON.utf8.count)"
        )
        if responseJSON.contains("invalid_json") {
            let locallyValid = (try? JSONSerialization.jsonObject(
                with: Data(requestJSON.utf8)
            )) != nil
            print(
                "Logseq debug: invalid_json action=\(actionName) "
                    + "bytes=\(requestJSON.utf8.count) locallyValid=\(locallyValid)"
            )
        }
        #endif
        logger.info("Core action returned: \(actionName)")
        if shouldApply?() ?? true {
            apply(responseJSON: responseJSON, actionName: actionName)
        }
    }

    nonisolated private static func callInBackground(
        _ callCore: @escaping @Sendable (String) -> String,
        requestJSON: String,
        actionName: String
    ) async -> String {
        await Task.detached(priority: .utility) {
            callCore(requestJSON)
        }.value
    }

    private func encode(_ request: LogseqRPCRequest) -> String? {
        do {
            let params = request.params
            let projectedRequest = LogseqRPCRequest(method: request.method, params: LogseqRPCParams(
                action: params.action, payload: params.payload, path: params.path, projection: "snapshot"
            ))
            let requestData = try JSONEncoder().encode(projectedRequest)
            guard let requestJSON = String(data: requestData, encoding: .utf8) else {
                lastError = LogseqCoreError(code: "request_encoding", message: "Could not encode request")
                logger.error("Core request encoding failed: request was not UTF-8")
                return nil
            }
            return requestJSON
        } catch {
            lastError = LogseqCoreError(code: "request_encoding", message: "\(error)")
            logger.error("Core request encoding failed: message: \(String(describing: error))")
            return nil
        }
    }

    private func encodePayload<T: Encodable>(_ value: T, action: String) -> String? {
        do {
            let data = try JSONEncoder().encode(value)
            guard let payload = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            return payload
        } catch {
            lastError = LogseqCoreError(code: "request_encoding", message: "\(error)")
            logger.error("Core request encoding failed: \(action)")
            return nil
        }
    }

    private func apply(responseJSON: String, actionName: String = "sync") {
        #if DEBUG
        let applyStartedAt = Date()
        #endif
        do {
            let responseData = Data(responseJSON.utf8)
            if actionName == "handleDeepLink" {
                struct Envelope: Decodable { struct Result: Decodable { let deepLinkQuickAction: String? }; let result: Result? }
                deepLinkQuickAction = try JSONDecoder().decode(Envelope.self, from: responseData).result?.deepLinkQuickAction
            }
            if actionName == "bootstrapGraph" {
                bootstrapPlan = try JSONDecoder().decode(LogseqBootstrapEnvelope.self, from: responseData).result?.graphBootstrap
                graphSyncAllowed = bootstrapPlan?.syncAllowed == true
            }
            if actionName == "beginSyncTransport" || actionName == "syncTransportEvent" {
                syncTransport = try JSONDecoder().decode(LogseqSyncTransportEnvelope.self, from: responseData).result?.syncTransport
            }
            if actionName == "beginPendingSync" || actionName == "completePendingSync" {
                let pendingError = try JSONDecoder().decode(LogseqSyncTransportEnvelope.self, from: responseData).result?.pendingSyncError
                if let pendingError {
                    syncError = LogseqCoreError(code: "pending_sync_failed", message: pendingError)
                } else if syncError?.code == "pending_sync_failed" {
                    syncError = nil
                }
            }
            let response = try JSONDecoder().decode(LogseqRPCResponse.self, from: responseData)
            if response.ok, let result = response.result {
                #if DEBUG
                let applyMilliseconds = Date().timeIntervalSince(applyStartedAt) * 1_000
                print(
                    "Logseq debug: core action applied \(actionName) "
                        + "revision=\(result.revision) blocks=\(result.blocks.count) "
                        + "journals=\(result.blocks.filter { $0.journalDay != nil }.count) "
                        + "graphs=\(result.graphs?.count ?? 0) "
                        + "patch=\(result.isOutlinerPatch) "
                        + "applyMs=\(String(format: "%.2f", applyMilliseconds))"
                )
                #endif
                logger.info(
                    "Core action applied: \(actionName), revision: \(result.revision), blocks: \(result.blocks.count), graph: \(result.graphName ?? "none")"
                )
                snapshot = result
                lastError = nil
                if actionName == "openGraph" {
                    debugDatabaseRoute = "graph:\(result.selectedGraphId ?? "unknown")"
                    syncError = nil
                } else if actionName == "open" {
                    debugDatabaseRoute = "catalog:\(openedDatabasePath ?? "unknown")"
                    syncError = nil
                }
            } else {
                let error = response.error ?? LogseqCoreError(code: "unknown_core_error", message: "The core returned no snapshot")
                #if DEBUG
                print(
                    "Logseq debug: core action failed \(actionName) "
                        + "code=\(error.code) message=\(error.message)"
                )
                #endif
                logger.error(
                    "Core action failed: \(actionName), code: \(error.code), message: \(error.message)"
                )
                lastError = error
            }
        } catch {
            let coreError = LogseqCoreError(code: "response_decoding", message: "\(error)")
            logger.error(
                "Core response decoding failed: \(actionName), message: \(coreError.message)"
            )
            lastError = coreError
        }
        responseObserver(responseJSON)
    }

    private static func normalizedBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "https://staging-api.logseq.io" {
            return "https://api-staging.logseq.io"
        }
        if trimmed == "http://staging-api.logseq.io" {
            return "https://api-staging.logseq.io"
        }
        return trimmed
    }

    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    private static func corePriority(for action: String) -> LogseqCorePriority {
        switch action {
        case "selectGraph", "captureShared", "handleDeepLink", "outlinerEvent", "selectPage", "clearSelectedPage", "openNode", "closeNode",
             "select", "clearSelection", "loadOlderJournals", "searchNodes", "send", "sendTask",
             "addAsset", "addChildBlock", "updateBlock", "updateBlockStatus", "deleteBlock":
            return .interaction
        case "open", "configure", "refresh", "refreshGraphCatalog", "createSyncGraph", "openGraph",
             "importSnapshot", "startWebSocket", "applySyncEvent", "stopWebSocket", "beginPendingSync",
             "completePendingSync", "cancelPendingSync":
            return .maintenance
        default:
            return .normal
        }
    }

}
