import SwiftUI
import Logseq
import AppIntents

private typealias AppRootView = LogseqRootView
private typealias AppDelegate = LogseqAppDelegate

/// The entry point to the app simply loads the App implementation from SPM module.
@main struct AppMain: App {
    @AppDelegateAdaptor(AppMainDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .active:
                AppDelegate.shared.onResume()
            case .inactive:
                AppDelegate.shared.onPause()
            case .background:
                AppDelegate.shared.onStop()
                LogseqBackgroundRefresh.syncNow()
                LogseqBackgroundRefresh.schedule()
            @unknown default:
                print("unknown app phase: \(newPhase)")
            }
        }
    }
}

typealias AppDelegateAdaptor = UIApplicationDelegateAdaptor
typealias AppMainDelegateBase = UIApplicationDelegate
typealias AppType = UIApplication

@MainActor final class AppMainDelegate: NSObject, AppMainDelegateBase {
    let application = AppType.shared

    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        AppDelegate.shared.onInit()
        return true
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        AppDelegate.shared.onLaunch()
        LogseqBackgroundRefresh.register()
        LogseqBackgroundRefresh.schedule()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = session.configuration
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppDelegate.shared.onDestroy()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        AppDelegate.shared.onLowMemory()
    }

    // Support notification token retrieval from the app runtime.

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: NSNotification.Name("didRegisterForRemoteNotificationsWithDeviceToken"), object: application, userInfo: ["deviceToken": deviceToken])
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        NotificationCenter.default.post(name: NSNotification.Name("didFailToRegisterForRemoteNotificationsWithError"), object: application, userInfo: ["error": error])
    }

}

@MainActor final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem {
            _ = perform(item)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(perform(shortcutItem))
    }

    private func perform(_ item: UIApplicationShortcutItem) -> Bool {
        guard ["logseq://capture", "logseq://audio"].contains(item.type),
              let url = URL(string: item.type) else { return false }
        LogseqLogseqRuntime.shared.acceptSharedCaptureURL(url)
        return true
    }
}

@available(iOS 17.0, *)
struct CaptureToJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture to Journal"
    static let description = IntentDescription("Add text to today's Logseq journal.")
    static let openAppWhenRun = true

    @Parameter(
        title: "Text",
        requestValueDialog: IntentDialog("What would you like to capture?")
    )
    var text: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard ShortcutCapture.enqueue(text) else {
            return .result(dialog: "Enter some text to capture.")
        }
        LogseqLogseqRuntime.shared.processSharedCaptures()
        return .result(dialog: "Added to today's journal.")
    }
}

@available(iOS 17.0, *)
struct LogseqAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickAddIntent(),
            phrases: ["Quick add in \(.applicationName)", "Add note in \(.applicationName)"],
            shortTitle: "Quick Add",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: RecordAudioIntent(),
            phrases: ["Record audio in \(.applicationName)", "Start recording in \(.applicationName)"],
            shortTitle: "Record Audio",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: OpenJournalIntent(),
            phrases: ["Open today's journal in \(.applicationName)"],
            shortTitle: "Today's Journal",
            systemImageName: "book"
        )
        AppShortcut(
            intent: CaptureToJournalIntent(),
            phrases: [
                "Capture in \(.applicationName)",
                "Add to my \(.applicationName) journal"
            ],
            shortTitle: "Capture",
            systemImageName: "square.and.pencil"
        )
    }
}
