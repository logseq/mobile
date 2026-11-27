import SwiftUI
import Logseq
import AppIntents
import UniformTypeIdentifiers
import UserNotifications

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
    private let discussionNotifications = DiscussionNotificationDelegate()

    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        AppDelegate.shared.onInit()
        return true
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        AppDelegate.shared.onLaunch()
        UNUserNotificationCenter.current().delegate = discussionNotifications
        LogseqBackgroundRefresh.register()
        LogseqBackgroundRefresh.schedule()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        for context in options.urlContexts {
            LogseqLogseqRuntime.shared.prepareInitialWidgetLink(context.url)
        }
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

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        LogseqLogseqRuntime.shared.resumePendingWidgetRefresh()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        LGDiscussionPush.shared.registered(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        LGDiscussionPush.shared.registrationFailed(error)
    }
}

private final class DiscussionNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let payload = response.notification.request.content.userInfo
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let graph = payload["graphId"] as? String, let event = payload["eventId"] as? String else { return }
        await LogseqLogseqRuntime.shared.openDiscussionPush(graphID: graph, eventID: event)
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
struct JournalCaptureGraph: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Logseq Graph"
    static let defaultQuery = JournalCaptureGraphQuery()
    static let recentID = "logseq:last-shortcut-capture"

    let id: String
    let name: String?

    var displayRepresentation: DisplayRepresentation {
        if id == Self.recentID {
            if let name { return DisplayRepresentation(title: "Last Used Graph", subtitle: "\(name)") }
            return DisplayRepresentation(title: "Last Used Graph")
        }
        return DisplayRepresentation(title: "\(name ?? id)")
    }

    var explicitGraphID: String? { id == Self.recentID ? nil : id }
}

@available(iOS 17.0, *)
struct JournalCaptureGraphQuery: EntityQuery {
    @MainActor func suggestedEntities() async -> [JournalCaptureGraph] {
        let graphs = await LogseqJournalShortcutCapture.availableGraphs()
        return [recentGraph(in: graphs)] + graphs.map { JournalCaptureGraph(id: $0.id, name: $0.name) }
    }

    @MainActor func entities(for identifiers: [String]) async -> [JournalCaptureGraph] {
        let graphs = await suggestedEntities()
        return identifiers.compactMap { id in graphs.first { $0.id == id } }
    }

    @MainActor func defaultResult() async -> JournalCaptureGraph? {
        recentGraph(in: await LogseqJournalShortcutCapture.availableGraphs())
    }

    @MainActor private func recentGraph(in graphs: [LogseqJournalShortcutCapture.Graph]) -> JournalCaptureGraph {
        let name = LogseqJournalShortcutCapture.defaultGraph(in: graphs)?.name
        return JournalCaptureGraph(id: JournalCaptureGraph.recentID, name: name)
    }
}

@available(iOS 17.0, *)
struct CaptureToJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture to Journal"
    static let description = IntentDescription("Add text to today's Logseq journal.")
    static let openAppWhenRun = false

    @Parameter(
        title: "Text",
        requestValueDialog: IntentDialog("What would you like to capture?")
    )
    var text: String

    @Parameter(title: "Graph")
    var graph: JournalCaptureGraph?

    static var parameterSummary: some ParameterSummary {
        Summary("Capture \(\.$text) in \(\.$graph)")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try await captureJournalText(text, task: false, graphID: graph?.explicitGraphID)
        return .result(dialog: "Added to today's journal.")
    }
}

@available(iOS 17.0, *)
struct CaptureTaskToJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Task to Journal"
    static let description = IntentDescription("Add a task to today's Logseq journal.")
    static let openAppWhenRun = false

    @Parameter(title: "Task", requestValueDialog: IntentDialog("What task would you like to capture?"))
    var text: String

    @Parameter(title: "Graph")
    var graph: JournalCaptureGraph?

    static var parameterSummary: some ParameterSummary {
        Summary("Capture task \(\.$text) in \(\.$graph)")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try await captureJournalText(text, task: true, graphID: graph?.explicitGraphID)
        return .result(dialog: "Added a task to today's journal.")
    }
}

private enum JournalShortcutError: LocalizedError {
    case emptyText
    case invalidPhoto
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .emptyText: String(localized: "Enter some text to capture.")
        case .invalidPhoto: String(localized: "Choose an image to capture.")
        case .captureFailed: String(localized: "Could not save to the journal. Choose a downloaded graph that is unlocked in Logseq.")
        }
    }
}

@MainActor private func captureJournalText(_ text: String, task: Bool, graphID: String?) async throws {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw JournalShortcutError.emptyText }
    guard await LogseqJournalShortcutCapture.captureText(text, task: task, graphID: graphID) else {
        throw JournalShortcutError.captureFailed
    }
}

@available(iOS 17.0, *)
struct TakePictureIntent: AppIntent {
    static let title: LocalizedStringResource = "Take Picture"
    static let description = IntentDescription("Open the camera in the Logseq journal composer.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        LogseqLogseqRuntime.shared.acceptSharedCaptureURL(URL(string: "logseq://camera")!)
        return .result()
    }
}

@available(iOS 17.0, *)
struct CapturePhotoToJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Photo to Journal"
    static let description = IntentDescription("Save a photo to today's Logseq journal. Use after Take Photo in Shortcuts.")
    static let openAppWhenRun = false

    @Parameter(title: "Photo")
    var photo: IntentFile

    @Parameter(title: "Graph")
    var graph: JournalCaptureGraph?

    static var parameterSummary: some ParameterSummary {
        Summary("Capture photo \(\.$photo) in \(\.$graph)")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let title = URL(fileURLWithPath: photo.filename).lastPathComponent
        let type = if let type = photo.type, type.conforms(to: .image) {
            type
        } else {
            UTType(filenameExtension: (title as NSString).pathExtension)
        }
        guard let type, type.conforms(to: .image) else { throw JournalShortcutError.invalidPhoto }
        let data = photo.data
        guard !data.isEmpty else { throw JournalShortcutError.invalidPhoto }
        guard await LogseqJournalShortcutCapture.capturePhoto(
            data, title: title, contentType: type.preferredMIMEType ?? type.identifier, graphID: graph?.explicitGraphID
        ) else { throw JournalShortcutError.captureFailed }
        return .result(dialog: "Added a photo to today's journal.")
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
        AppShortcut(
            intent: CaptureTaskToJournalIntent(),
            phrases: ["Capture a task in \(.applicationName)"],
            shortTitle: "Capture Task",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: TakePictureIntent(),
            phrases: ["Take a picture in \(.applicationName)"],
            shortTitle: "Take Picture",
            systemImageName: "camera"
        )
    }
}
