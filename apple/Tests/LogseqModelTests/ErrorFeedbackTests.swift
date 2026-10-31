import Foundation
import Testing
@testable import LogseqModel

private final class ErrorMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ message: String) { lock.withLock { storage.append(message) } }
    var values: [String] { lock.withLock { storage } }
}

@Suite struct ErrorFeedbackTests {
    @Test func lastErrorSurvivesFiltersEvictionAndRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("last-error.json")
        let log = LogseqRuntimeLog(capacity: 1, persistenceURL: path)
        log.append(level: .error, source: .ui, message: "Last authentication failure")
        log.append(level: .info, source: .core, message: "Connected")
        #expect(log.records(source: .core, errorsOnly: true).isEmpty)
        #expect(log.lastError?.message == "Last authentication failure")
        let reopened = LogseqRuntimeLog(persistenceURL: path)
        #expect(reopened.records().isEmpty)
        #expect(reopened.lastError == log.lastError)
        reopened.append(level: .error, source: .core, message: "New sync failure")
        #expect(reopened.lastError?.message == "New sync failure")
        #expect((reopened.lastError?.id ?? 0) > (log.lastError?.id ?? 0))
    }

    @Test @MainActor func releaseErrorsStayInTheLogWithoutAlerts() {
        let messages = ErrorMessages()
        let log = LogseqRuntimeLog(onError: { messages.append($0) })
        let feedback = LogseqErrorFeedback(showsAlerts: false)
        log.append(level: .error, source: .ui, message: "Authentication failed")
        log.append(level: .error, source: .core, message: "Sync failed")
        log.append(level: .info, source: .ui, message: "Opened graph")
        for message in messages.values { feedback.receive(message) }
        #expect(messages.values == ["Authentication failed", "Sync failed"])
        #expect(log.records(errorsOnly: true).map(\.message) == messages.values)
        #expect(feedback.message == nil)
    }

    @Test @MainActor func debugErrorsUseOneDismissibleAlert() {
        let feedback = LogseqErrorFeedback(showsAlerts: true)
        feedback.receive("")
        #expect(feedback.message == nil)
        feedback.receive("First error")
        feedback.receive("First error")
        feedback.receive("Second error")
        #expect(feedback.message == "Second error")
        feedback.dismiss()
        #expect(feedback.message == nil)
        feedback.receive("First error")
        #expect(feedback.message == "First error")
    }

    @Test func buildConfigurationSelectsTheDefaultPresentation() {
        #if DEBUG
        #expect(LogseqErrorFeedback.alertsEnabledByDefault)
        #else
        #expect(!LogseqErrorFeedback.alertsEnabledByDefault)
        #endif
    }
}
