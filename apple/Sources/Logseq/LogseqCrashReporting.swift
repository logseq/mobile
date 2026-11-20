#if os(iOS)
import Foundation
import SentrySwift

enum LogseqCrashReporting {
    nonisolated static func start(dsn: String = "https://97cf2c1b0b73bc127f78ad8802e6be9f@o416451.ingest.us.sentry.io/4512448516194305") {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["LOGSEQ_SENTRY_DEBUG"] == "1" else { return }
        let environment = "development"
        #else
        let environment = "production"
        #endif

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment
            options.sendDefaultPii = false
            options.enableAutoSessionTracking = false
            options.enableAutoBreadcrumbTracking = true
            options.enableNetworkBreadcrumbs = true
            options.maxBreadcrumbs = 50
            options.beforeBreadcrumb = { breadcrumb in safeBreadcrumb(breadcrumb) }
            options.beforeSend = scrub
        }
        if let revision = Bundle.main.object(forInfoDictionaryKey: "LogseqRevision") as? String {
            SentrySDK.configureScope { $0.setTag(value: revision, key: "git_revision") }
        }
    }

    nonisolated static func safeBreadcrumb(_ breadcrumb: Breadcrumb) -> Breadcrumb? {
        let data = breadcrumb.data ?? [:]
        var safe: [String: Any] = [:]
        switch breadcrumb.category {
        case "app.lifecycle":
            guard let state = data["state"] as? String,
                  ["foreground", "background", "active", "inactive"].contains(state) else { return nil }
            safe["state"] = state
        case "device.event":
            guard data["action"] as? String == "LOW_MEMORY" else { return nil }
            safe["action"] = "LOW_MEMORY"
        case "device.connectivity":
            guard let state = data["connectivity"] as? String,
                  ["wifi", "cellular", "ethernet", "none", "offline"].contains(state) else { return nil }
            safe["connectivity"] = state
        case "ui.lifecycle":
            guard let screen = data["screen"] as? String,
                  !screen.isEmpty, screen.count < 200,
                  screen.range(of: "^[A-Za-z_][A-Za-z0-9_.]*(?:<[A-Za-z0-9_., <>]+>)?$", options: .regularExpression) != nil else { return nil }
            safe["screen"] = screen
        case "http":
            guard let method = data["method"] as? String,
                  ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(method),
                  let rawURL = data["url"] as? String,
                  let url = URLComponents(string: rawURL),
                  let scheme = url.scheme, ["https", "http"].contains(scheme),
                  let host = url.host else { return nil }
            safe["method"] = method
            safe["host"] = host
            if let status = data["status_code"] as? Int, (100...599).contains(status) {
                safe["status_code"] = status
            }
        case "runtime":
            guard let state = data["state"] as? String,
                  ["start", "started", "drain_begin", "drain_end"].contains(state) else { return nil }
            safe["state"] = state
        default:
            return nil
        }
        let result = Breadcrumb(level: breadcrumb.level, category: breadcrumb.category)
        result.timestamp = breadcrumb.timestamp
        result.data = safe
        return result
    }

    enum RuntimeState: String {
        case start, started, drainBegin = "drain_begin", drainEnd = "drain_end"
    }

    nonisolated static func runtime(_ state: RuntimeState) {
        let breadcrumb = Breadcrumb(level: .info, category: "runtime")
        breadcrumb.data = ["state": state.rawValue]
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    nonisolated static func scrub(_ event: Event) -> Event? {
        // Exception reasons can contain graph names, paths, or user content.
        event.exceptions?.forEach { exception in
            if exception.type != nil { exception.value = nil }
        }
        event.user = nil
        event.request = nil
        return event
    }
}
#endif
