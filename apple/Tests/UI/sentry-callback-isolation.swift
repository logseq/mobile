import Foundation
import SentrySwift
import SwiftUI

@main struct SentryCallbackIsolationCheck: App {
    var body: some Scene {
        WindowGroup {
            Text("Sentry callback check").task {
                let dsn = "https://public@127.0.0.1:9/0"
                LogseqCrashReporting.start(dsn: dsn)
                precondition(SentrySDK.internal.options.dsn == dsn)
                print("SENTRY_CHECK_DSN=\(SentrySDK.internal.options.dsn!)")
                fflush(stdout)
                LogseqCrashReporting.uiState(screen: .page, editorActive: true)
                for _ in 0..<30 {
                    LogseqCrashReporting.runtime(.drainBegin)
                    LogseqCrashReporting.runtime(.drainEnd)
                }
                LogseqCrashReporting.uiState(screen: .page, editorActive: true)
                await Task.detached {
                    precondition(!Thread.isMainThread)
                    // Exercise the actual installed callback without uploading test events.
                    let callback = SentrySDK.internal.options.beforeSend!
                    let beforeBreadcrumb = SentrySDK.internal.options.beforeBreadcrumb!
                    let cases: [(String, [String: Any], [String: Any]?)] = [
                        ("app.lifecycle", ["state": "active", "title": "private"], ["state": "active"]),
                        ("device.event", ["action": "LOW_MEMORY"], ["action": "LOW_MEMORY"]),
                        ("device.connectivity", ["connectivity": "wifi"], ["connectivity": "wifi"]),
                        ("ui.lifecycle", ["screen": "Logseq.Controller", "title": "private"], ["screen": "Logseq.Controller"]),
                        ("ui.lifecycle", ["screen": "UIHostingController<ModifiedContent<AnyView, AnyView>>", "title": "private"], ["screen": "UIHostingController<ModifiedContent<AnyView, AnyView>>"]),
                        ("http", ["method": "GET", "url": "https://user:token@example.com/private?q=secret#title"], ["method": "GET", "host": "example.com"]),
                        ("runtime", ["state": "drain_begin"], ["state": "drain_begin"]),
                        ("ui.state", ["screen": "page", "native_search_active": false, "editor_active": true,
                                      "popover_open": false, "capture_rail_visible": true, "title": "private"],
                         ["screen": "page", "native_search_active": false, "editor_active": true,
                          "popover_open": false, "capture_rail_visible": true]),
                        ("console", ["message": "private"], nil),
                        ("ui.click", ["title": "private"], nil),
                        ("unknown", [:], nil),
                        ("app.lifecycle", [:], nil),
                        ("http", ["method": "GET", "url": "not a URL"], nil),
                        ("ui.lifecycle", ["screen": "private title"], nil)
                    ]
                    for (category, data, expected) in cases {
                        let crumb = Breadcrumb(level: .info, category: category)
                        crumb.data = data
                        crumb.message = "private message"
                        let result = beforeBreadcrumb(crumb)
                        if let expected {
                            precondition(NSDictionary(dictionary: result?.data ?? [:]).isEqual(to: expected))
                            precondition(result?.message == nil)
                        } else {
                            precondition(result == nil)
                        }
                    }
                    print("PASS: background beforeBreadcrumb retains only allowlisted diagnostic fields; drops content, empty and malformed breadcrumbs")
                    SentrySDK.configureScope { scope in
                        let serialized = scope.serialize()
                        let contexts = serialized["context"] as? [String: [String: Any]]
                        let expected: [String: Any] = ["screen": "page", "native_search_active": false,
                            "editor_active": true, "popover_open": false, "capture_rail_visible": false]
                        precondition(NSDictionary(dictionary: contexts?["ui_state"] ?? [:]).isEqual(to: expected))
                        let breadcrumbs = serialized["breadcrumbs"] as? [[String: Any]] ?? []
                        precondition(breadcrumbs.count == 50)
                        precondition(!breadcrumbs.contains { $0["category"] as? String == "ui.state" })
                        let event = Event(level: .error)
                        event.context = contexts
                        precondition(callback(event) === event)
                        precondition(NSDictionary(dictionary: event.context?["ui_state"] ?? [:]).isEqual(to: expected))
                    }
                    print("PASS: deduplicated UI state survives breadcrumb eviction in scope and beforeSend context")
                    SentrySDK.close()
                    let event = Event(level: .error)
                    let typed = Exception(value: "private graph/path", type: "ExampleError")
                    let untyped = Exception(value: "reason without type", type: nil)
                    event.exceptions = [typed, untyped]
                    event.user = User(userId: "private-user")
                    event.request = SentryRequest()
                    precondition(callback(event) === event)
                    precondition(typed.value == nil && typed.type == "ExampleError")
                    precondition(untyped.value == "reason without type")
                    precondition(event.user == nil && event.request == nil)
                    let empty = Event()
                    precondition(callback(empty) === empty)
                    precondition(empty.exceptions == nil && empty.user == nil && empty.request == nil)
                    print("PASS: background beforeSend scrubs typed exceptions, user and request; preserves untyped reasons and empty events")
                    fflush(stdout)
                    exit(0)
                }.value
            }
        }
    }
}
