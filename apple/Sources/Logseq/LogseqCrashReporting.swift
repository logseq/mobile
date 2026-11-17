#if os(iOS)
import Foundation
import SentrySwift

enum LogseqCrashReporting {
    @MainActor static func start() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["LOGSEQ_SENTRY_DEBUG"] == "1" else { return }
        let environment = "development"
        #else
        let environment = "production"
        #endif

        SentrySDK.start { options in
            options.dsn = "https://97cf2c1b0b73bc127f78ad8802e6be9f@o416451.ingest.us.sentry.io/4512448516194305"
            options.environment = environment
            options.sendDefaultPii = false
            options.enableAutoSessionTracking = false
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.maxBreadcrumbs = 0
            options.beforeSend = { event in
                // Exception reasons can contain graph names, paths, or user content.
                event.exceptions?.forEach { exception in
                    if exception.type != nil { exception.value = nil }
                }
                event.user = nil
                event.request = nil
                return event
            }
        }
        if let revision = Bundle.main.object(forInfoDictionaryKey: "LogseqRevision") as? String {
            SentrySDK.configureScope { $0.setTag(value: revision, key: "git_revision") }
        }
    }
}
#endif
