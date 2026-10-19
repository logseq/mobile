import Foundation
import LogseqCoreABI

public struct LogseqGraphDownloadProgress: Codable, Equatable, Identifiable, Sendable {
    public var id: String { graphId }
    public let graphId: String
    public let graphName: String
    public let phase: String
    public let completedItems: Int64
    public let totalItems: Int64?
}

@MainActor enum GraphImportProgressRelay {
    static var report: ((String, String, Int64, Int64?) -> Void)?
}

@_cdecl("logseq_receive_graph_import_progress")
func receiveGraphImportProgress(_ graphID: UnsafePointer<CChar>?, _ phase: UnsafePointer<CChar>?,
                                _ completed: Int64, _ total: Int64) {
    guard let graphID, let phase else { return }
    let id = String(cString: graphID)
    let stage = String(cString: phase)
    Task { @MainActor in GraphImportProgressRelay.report?(id, stage, completed, total >= 0 ? total : nil) }
}
