import Foundation
import LogseqModel

struct LGGraphSnapshotEnvelope: Codable {
    let apiVersion: Int
    let ok: Bool
    let result: LogseqSnapshot
}

enum LGGraphEffectResolution {
    static func make(
        succeeded: Bool,
        snapshot: LogseqSnapshot,
        errorMessage: String?
    ) -> LGEffectResolution {
        guard succeeded else {
            return LGEffectResolution(
                succeeded: false,
                message: errorMessage ?? "The graph operation failed",
                output: .discard
            )
        }
        do {
            let data = try JSONEncoder().encode(LGGraphSnapshotEnvelope(
                apiVersion: 1,
                ok: true,
                result: snapshot
            ))
            guard let message = String(data: data, encoding: .utf8) else {
                throw LGGraphSnapshotEncodingError.invalidUTF8
            }
            return LGEffectResolution(
                succeeded: true,
                message: message,
                output: .coreResponse
            )
        } catch {
            return LGEffectResolution(
                succeeded: false,
                message: "Could not encode the graph snapshot: \(error)",
                output: .discard
            )
        }
    }
}

private enum LGGraphSnapshotEncodingError: Error {
    case invalidUTF8
}

@MainActor
final class LGGraphLifecycle {
    var localGraphIDsChanged: (([String]) -> Void)?

    private let store: LogseqStore
    private let authentication: LogseqAuthenticationStore
    private let syncCoordinator: GraphSyncCoordinator
    private let databasePath: String
    private let openCreatedGraph: (@MainActor (String) async -> LGEffectResolution)?
    private var residentPreparation: Task<Void, Never>?
    private var residentGraphIDs: [String]?

    init(
        store: LogseqStore,
        authentication: LogseqAuthenticationStore,
        syncCoordinator: GraphSyncCoordinator,
        databasePath: String,
        openCreatedGraph: (@MainActor (String) async -> LGEffectResolution)? = nil
    ) {
        self.store = store
        self.authentication = authentication
        self.syncCoordinator = syncCoordinator
        self.databasePath = databasePath
        self.openCreatedGraph = openCreatedGraph
    }

    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        switch effect.kind {
        case "open-graph":
            return await openGraph(effect.text)
        case "unlock-graph":
            return await unlockGraph(effect.text)
        case "create-graph":
            guard await store.createSyncGraph(
                name: effect.text,
                isEncrypted: effect.value == 1,
                password: effect.metadata
            ), let graphID = store.snapshot.selectedGraphId, !graphID.isEmpty else {
                return resolution(succeeded: false)
            }
            let openResolution = if let openCreatedGraph {
                await openCreatedGraph(graphID)
            } else {
                await openGraph(graphID, persistSelection: false)
            }
            guard openResolution.succeeded else { return openResolution }
            UserDefaults.standard.set(graphID, forKey: "logseq.selectedGraphId")
            return openResolution
        case "delete-local-graph":
            return await deleteLocalGraph(effect.text)
        default:
            return LGEffectResolution(
                succeeded: false,
                message: "Unsupported graph platform effect: \(effect.kind)",
                output: .discard
            )
        }
    }

    func reconfigureAPI() async throws {
        residentPreparation?.cancel()
        residentGraphIDs = nil
        let token = authentication.state == .signedIn
            ? try await authentication.apiToken() : ""
        await syncCoordinator.cancelBackground()
        await syncCoordinator.stopForeground()
        let defaults = UserDefaults.standard
        defaults.set("", forKey: "logseq.selectedGraphId")
        defaults.removeObject(forKey: "logseq.uiSession")
        await store.openAndWait(path: databasePath)
        await store.configureAndSelectGraph(
            baseURL: LogseqSettingsPolicy.storedBaseURL(in: defaults),
            token: token,
            selectedGraphID: nil
        )
    }

    func connectStoredGraph() async -> Bool {
        let defaults = UserDefaults.standard
        let baseURL = LogseqSettingsPolicy.storedBaseURL(in: defaults)
        let storedGraphID = defaults.string(forKey: "logseq.selectedGraphId") ?? ""
        let graphID = storedGraphID.isEmpty ? nil : storedGraphID
        let accessToken = (try? await authentication.apiToken()) ?? ""
        await store.configureAndSelectGraph(
            baseURL: baseURL,
            token: accessToken,
            selectedGraphID: graphID
        )
        guard store.lastError == nil else { return false }
        guard let graphID else { return true }

        guard await store.bootstrapSelectedGraph(
            graphID: graphID,
            baseURL: baseURL,
            accessToken: accessToken,
            allowSnapshotDownload: !accessToken.isEmpty
        ) else { return false }
        if store.graphSyncAllowed { startSync(graphID: graphID, baseURL: baseURL) }
        prepareResidentGraphs(force: true)
        return true
    }

    func prepareResidentGraphs(force: Bool = false) {
        #if os(iOS)
        let slots = UserDefaults.standard.stringArray(forKey: "logseq.mobile.graphQuickSlots") ?? []
        let graphs = slots.prefix(3).compactMap { id in
            store.snapshot.graphs?.first { $0.id == id && $0.isReady }
        }
        let ids = graphs.map(\.id)
        guard force || ids != residentGraphIDs else { return }
        residentPreparation?.cancel()
        residentGraphIDs = ids
        let active = store.snapshot.selectedGraphId
        residentPreparation = Task { [databasePath] in
            guard !Task.isCancelled else { return }
            await Self.sendResidencyRequest("retainGraphs", payload: ["ids": ids])
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            for graph in graphs where graph.id != active && !graph.isEncrypted {
                guard !Task.isCancelled else { return }
                let directory = LogseqGraphLocalStorage.directoryURL(
                    databasePath: databasePath, graphID: graph.id, graphName: graph.name
                )
                let database = directory.appendingPathComponent("graph.sqlite").path
                let checkpoint = directory.appendingPathComponent("sync.checkpoint").path
                guard FileManager.default.fileExists(atPath: database),
                      FileManager.default.fileExists(atPath: checkpoint) else { continue }
                await Self.sendResidencyRequest("prepareGraph", payload: [
                    "graphId": graph.id, "activePath": database, "checkpointPath": checkpoint,
                    "isEncrypted": false,
                ])
            }
        }
        #endif
    }

    func clearResidentGraphs() async {
        residentPreparation?.cancel()
        residentGraphIDs = nil
        await Self.sendResidencyRequest("retainGraphs", payload: ["ids": [String]()])
    }

    private static func sendResidencyRequest(_ action: String, payload: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        _ = await LogseqCore.callAsync(LogseqRPCRequest(method: "dispatch", params: LogseqRPCParams(
            action: action, payload: String(decoding: data, as: UTF8.self)
        )))
    }

    private func openGraph(
        _ graphID: String,
        persistSelection: Bool = true
    ) async -> LGEffectResolution {
        guard await store.selectGraphAndWait(graphID) else {
            return resolution(succeeded: false)
        }

        let baseURL = LogseqSettingsPolicy.storedBaseURL()
        let accessToken = (try? await authentication.apiToken()) ?? ""
        let opened = await store.bootstrapSelectedGraph(
            graphID: graphID,
            baseURL: baseURL,
            accessToken: accessToken,
            allowSnapshotDownload: !accessToken.isEmpty
        )
        guard opened else { return resolution(succeeded: false) }

        if persistSelection {
            UserDefaults.standard.set(graphID, forKey: "logseq.selectedGraphId")
        }
        publishLocalGraphIDs()
        prepareResidentGraphs()
        if store.graphSyncAllowed { startSync(graphID: graphID, baseURL: baseURL) }
        return resolution(succeeded: true)
    }

    private func unlockGraph(_ password: String) async -> LGEffectResolution {
        await store.unlockGraph(password)
        guard store.lastError == nil else {
            return LGEffectResolution(
                succeeded: false,
                message: store.lastError?.message ?? "The graph is still locked",
                output: .discard
            )
        }

        guard let graphID = store.snapshot.selectedGraphId,
              !graphID.isEmpty
        else {
            return LGEffectResolution(
                succeeded: false,
                message: "The unlocked graph has no selected identifier",
                output: .discard
            )
        }
        let baseURL = LogseqSettingsPolicy.storedBaseURL()
        let accessToken = (try? await authentication.apiToken()) ?? ""
        guard await store.bootstrapSelectedGraph(
            graphID: graphID, baseURL: baseURL, accessToken: accessToken,
            allowSnapshotDownload: !accessToken.isEmpty
        ) else { return resolution(succeeded: false) }
        if store.graphSyncAllowed { startSync(graphID: graphID, baseURL: baseURL) }
        return resolution(succeeded: true)
    }

    private func deleteLocalGraph(_ graphID: String) async -> LGEffectResolution {
        let defaults = UserDefaults.standard
        let deletingSelected = defaults.string(forKey: "logseq.selectedGraphId") == graphID
            || store.snapshot.selectedGraphId == graphID
        if deletingSelected {
            await syncCoordinator.stopForeground()
            await store.resetToCatalog(applyResponse: false)
        }
        do {
            try LogseqGraphLocalStorage.delete(databasePath: databasePath, graphID: graphID)
        } catch {
            return LGEffectResolution(
                succeeded: false,
                message: error.localizedDescription,
                output: .discard
            )
        }
        if deletingSelected {
            defaults.set("", forKey: "logseq.selectedGraphId")
            let accessToken = (try? await authentication.apiToken()) ?? ""
            await store.configureAndSelectGraph(
                baseURL: LogseqSettingsPolicy.storedBaseURL(in: defaults),
                token: accessToken,
                selectedGraphID: nil
            )
        }
        publishLocalGraphIDs()
        return resolution(succeeded: true)
    }

    private func publishLocalGraphIDs() {
        let graphIDs = (store.snapshot.graphs ?? []).compactMap { graph in
            LogseqGraphLocalStorage.isDownloaded(
                databasePath: databasePath,
                graphID: graph.id
            ) ? graph.id : nil
        }
        localGraphIDsChanged?(graphIDs)
    }

    private func resolution(succeeded: Bool) -> LGEffectResolution {
        LGGraphEffectResolution.make(
            succeeded: succeeded,
            snapshot: store.snapshot,
            errorMessage: store.lastError.map { $0.code + "\n" + $0.message }
        )
    }

    private func startSync(graphID: String, baseURL: String) {
        Task {
            await syncCoordinator.startForeground(graphID: graphID) { [weak self] graphID in
                guard let self else { return }
                while !Task.isCancelled && authentication.state == .signedIn {
                    guard let accessToken = try? await authentication.apiToken() else { return }
                    let snapshotRequired = await store.runGraphEventsOnce(
                        graphID: graphID, baseURL: baseURL, accessToken: accessToken
                    )
                    if snapshotRequired {
                        guard let refreshedToken = try? await authentication.apiToken() else { return }
                        let succeeded = await store.bootstrapSelectedGraph(
                            graphID: graphID, baseURL: baseURL, accessToken: refreshedToken,
                            forceSnapshot: true
                        )
                        await store.completeSyncSnapshot(succeeded: succeeded)
                    }
                    guard !Task.isCancelled else { return }
                    let delay = store.graphEventsRetryDelayMilliseconds
                    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                    else if !snapshotRequired { return }
                }
            }
        }
    }
}
