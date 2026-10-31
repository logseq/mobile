import Foundation
import Observation

@MainActor @Observable public final class LogseqErrorFeedback {
    public static let shared = LogseqErrorFeedback()
    #if DEBUG
    public nonisolated static let alertsEnabledByDefault = true
    #else
    public nonisolated static let alertsEnabledByDefault = false
    #endif

    public private(set) var message: String?
    private let showsAlerts: Bool

    public init(showsAlerts: Bool = alertsEnabledByDefault) {
        self.showsAlerts = showsAlerts
    }

    public func receive(_ message: String) {
        guard showsAlerts, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              self.message != message else { return }
        self.message = message
    }

    public func dismiss() {
        message = nil
    }
}
