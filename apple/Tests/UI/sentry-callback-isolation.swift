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
                await Task.detached {
                    precondition(!Thread.isMainThread)
                    // Exercise the actual installed callback without uploading test events.
                    let callback = SentrySDK.internal.options.beforeSend!
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
