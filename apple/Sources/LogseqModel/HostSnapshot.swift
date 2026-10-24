import Foundation

// The native shell consumes graph/session metadata. The complete UI projection
// stays in the original core response forwarded to the LUI renderer.
public struct LogseqHostResponse: Decodable {
    public struct Snapshot: Decodable {
        public let revision: Int
        public let graphName: String?
        public let selectedGraphId: String?
        public let graphs: [LogseqGraph]?
        public let lastRefreshAt: Int64?
        public let appliedServerT: Int?
        public let syncConnected: Bool?
        public let isGraphEncrypted: Bool?
        public let isGraphUnlocked: Bool?
        public let pendingSyncRequest: LogseqPendingSyncRequest?
        public let hasPendingSemanticOperations: Bool?
        public let isOutlinerPatch: Bool?
        public let isPendingSyncPatch: Bool?

        var hostSnapshot: LogseqSnapshot {
            LogseqSnapshot(revision: revision, blocks: [], selectedBlock: nil,
                lastRefreshAt: lastRefreshAt, graphName: graphName,
                selectedGraphId: selectedGraphId, graphs: graphs,
                appliedServerT: appliedServerT, syncConnected: syncConnected,
                isGraphEncrypted: isGraphEncrypted, isGraphUnlocked: isGraphUnlocked,
                pendingSyncRequest: pendingSyncRequest,
                hasPendingSemanticOperations: hasPendingSemanticOperations ?? false,
                isOutlinerPatch: isOutlinerPatch ?? false,
                isPendingSyncPatch: isPendingSyncPatch ?? false)
        }
    }

    public let apiVersion: Int
    public let ok: Bool
    public let result: Snapshot?
    public let error: LogseqCoreError?

    var hostResponse: LogseqRPCResponse {
        LogseqRPCResponse(apiVersion: apiVersion, ok: ok, result: result?.hostSnapshot, error: error)
    }
}
