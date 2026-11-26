import Foundation
import Logseq
import SentrySwift
internal import _SentryPrivate

@main struct SentryStartupCheck {
    @MainActor static func main() async throws {
        precondition(ProcessInfo.processInfo.environment["LOGSEQ_SENTRY_STARTUP_CHECK"] == "1")
        precondition(!SentrySDK.isEnabled, "Sentry started before the app's startup callback")

        LogseqAppDelegate.shared.onInit()
        defer { SentrySDK.close() }

        let options = SentrySDK.internal.options
        precondition(SentrySDK.isEnabled)
        precondition(options.dsn == "https://public@127.0.0.1:9/0")
        precondition(options.environment == "production")
        precondition(options.enableCrashHandler)
        precondition(SentrySDKInternal.currentHub().hasIntegration("SentryCrashIntegration"))
        print("PASS: app startup installed the production Sentry crash integration")
    }
}
