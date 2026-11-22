#if os(iOS)
import AppIntents
import Foundation
#if !WIDGET_EXTENSION
import Logseq
#endif

@MainActor private func openQuickAction(_ action: String) {
    #if !WIDGET_EXTENSION
    LogseqLogseqRuntime.shared.acceptSharedCaptureURL(URL(string: "logseq://\(action)")!)
    #endif
}

struct QuickAddIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Add"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        openQuickAction("capture")
        return .result()
    }
}

struct RecordAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Audio"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        openQuickAction("audio")
        return .result()
    }
}

struct OpenJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's Journal"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        openQuickAction("journal")
        return .result()
    }
}

struct SetWidgetTaskStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Set task status"
    static let openAppWhenRun = false
    static let isDiscoverable = false
    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    #endif
    #if compiler(>=6.4)
    @available(iOS 27.0, *)
    static let allowedExecutionTargets: IntentExecutionTargets = .main
    #endif

    @Parameter(title: "Graph ID") var graphId: String
    @Parameter(title: "Task ID") var uuid: String
    @Parameter(title: "Current status ID") var expectedStatusUuid: String
    @Parameter(title: "New status ID") var statusUuid: String

    init() {}

    init(graphId: String, uuid: String, expectedStatusUuid: String, statusUuid: String) {
        self.graphId = graphId
        self.uuid = uuid
        self.expectedStatusUuid = expectedStatusUuid
        self.statusUuid = statusUuid
    }

    @MainActor func perform() async throws -> some IntentResult {
        try await updateStatus()
        return .result()
    }

    @MainActor private func updateStatus() async throws {
        #if WIDGET_EXTENSION
        throw StatusError.unavailable
        #else
        guard await LogseqLogseqRuntime.shared.setWidgetTaskStatus(
            graphId: graphId, uuid: uuid, expectedStatusUuid: expectedStatusUuid, statusUuid: statusUuid
        ) else { throw StatusError.unavailable }
        try? WidgetTaskStatusSelection.clear(graphId: graphId, uuid: uuid)
        #endif
    }

    private enum StatusError: LocalizedError {
        case unavailable

        var errorDescription: String? { String(localized: "Could not update task status.") }
    }
}

struct WidgetTaskStatusSelection: Codable {
    let graphId: String
    let uuid: String
    let statusUuid: String
    let page: Int
    let expiresAt: Date

    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.logseq.logseq")?
            .appendingPathComponent("widget-task-status-selection.json")
    }

    static func read() -> Self? {
        guard let file, let data = try? Data(contentsOf: file),
              let selection = try? JSONDecoder().decode(Self.self, from: data),
              selection.expiresAt > .now else { return nil }
        return selection
    }

    func write() throws {
        guard let file = Self.file else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(self).write(to: file, options: [.atomic, .completeFileProtection])
    }

    static func clear(graphId: String, uuid: String) throws {
        guard let selection = read(), selection.graphId == graphId, selection.uuid == uuid,
              let file else { return }
        try FileManager.default.removeItem(at: file)
    }
}

struct ShowWidgetTaskStatusesIntent: AppIntent {
    static let title: LocalizedStringResource = "Choose task status"
    static let isDiscoverable = false
    #if compiler(>=6.4)
    @available(iOS 27.0, *)
    static let allowedExecutionTargets: IntentExecutionTargets = .widgetKitExtension
    #endif

    @Parameter(title: "Graph ID") var graphId: String
    @Parameter(title: "Task ID") var uuid: String
    @Parameter(title: "Current status ID") var statusUuid: String
    @Parameter(title: "Page") var page: Int

    init() {}

    init(graphId: String, uuid: String, statusUuid: String, page: Int) {
        self.graphId = graphId
        self.uuid = uuid
        self.statusUuid = statusUuid
        self.page = page
    }

    func perform() async throws -> some IntentResult {
        if page < 0 {
            try WidgetTaskStatusSelection.clear(graphId: graphId, uuid: uuid)
        } else {
            try WidgetTaskStatusSelection(graphId: graphId, uuid: uuid, statusUuid: statusUuid, page: page,
                expiresAt: .now.addingTimeInterval(300)).write()
        }
        return .result()
    }
}

struct RefreshRandomBlocksWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh random blocks"
    static let openAppWhenRun = false
    static let isDiscoverable = false
    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    #endif
    #if compiler(>=6.4)
    @available(iOS 27.0, *)
    static let allowedExecutionTargets: IntentExecutionTargets = .main
    #endif

    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await LogseqLogseqRuntime.shared.refreshRandomBlocksWidget()
        #endif
        return .result()
    }
}

#if !WIDGET_EXTENSION
extension SetWidgetTaskStatusIntent: ForegroundContinuableIntent {}
extension RefreshRandomBlocksWidgetIntent: ForegroundContinuableIntent {}
#endif

#endif
