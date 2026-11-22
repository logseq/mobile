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
        #endif
    }

    private enum StatusError: LocalizedError {
        case unavailable

        var errorDescription: String? { String(localized: "Could not update task status.") }
    }
}

#if !WIDGET_EXTENSION
extension SetWidgetTaskStatusIntent: ForegroundContinuableIntent {}
#endif

#endif
