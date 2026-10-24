import UIKit
import Security
import Logseq

@main @MainActor enum ApplicationEntryBenchmark {
    private static var observer: (any NSObjectProtocol)?
    private static var didObserveWindow = false

    static func main() {
        setbuf(stdout, nil)
        _ = Clock.processBirth
        Clock.mark("main_entry")
        precondition(Bundle.main.bundleIdentifier == "com.logseq.logseq.ColdStartAppEntry")
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
        for directory in [SharedCaptureStorage.queueDirectory, SharedCaptureStorage.sharedDirectory] {
            precondition(directory.resolvingSymlinksInPath().path.hasPrefix(home),
                "The application-entry control must not consume another app's shared captures")
        }
        if ProcessInfo.processInfo.environment["LOGSEQ_BENCH_PREPARE_SESSION"] == "1" {
            prepareSession()
            print("COLD_START_SESSION_READY")
            exit(0)
        }
        observer = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification,
            object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard !didObserveWindow, let window = notification.object as? UIWindow,
                      window.windowScene != nil, window.windowLevel == .normal,
                      window.rootViewController != nil else { return }
                didObserveWindow = true
                Clock.mark("window_became_key")
                Clock.begin("FirstLayout")
                FrameProbe.shared.start(in: window)
                if let observer { NotificationCenter.default.removeObserver(observer) }
                observer = nil
            }
        }
        AppMain.main()
    }

    private static func prepareSession() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.logseq.logseq.cognito.tokens",
            kSecAttrAccount: "current-session",
            kSecUseDataProtectionKeychain: true,
        ]
        // Synthetic credentials in this bundle's isolated keychain, with no refresh request.
        let data = try! JSONSerialization.data(withJSONObject: [
            "idToken": "eyJhbGciOiJub25lIn0.eyJzdWIiOiJiZW5jaG1hcmsifQ.",
            "refreshToken": "benchmark-unused",
            "expiresAt": Date().addingTimeInterval(3600).timeIntervalSinceReferenceDate,
        ])
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData] = data
            addition[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            precondition(SecItemAdd(addition as CFDictionary, nil) == errSecSuccess)
        } else { precondition(status == errSecSuccess) }
        let defaults = UserDefaults.standard
        guard let graphID = ProcessInfo.processInfo.environment["LOGSEQ_BENCH_GRAPH_ID"], !graphID.isEmpty else {
            fatalError("Set LOGSEQ_BENCH_GRAPH_ID to an existing graph in the isolated fixture")
        }
        defaults.set("http://127.0.0.1:1", forKey: "logseq.baseURL")
        defaults.set(graphID, forKey: "logseq.selectedGraphId")
        defaults.removeObject(forKey: "logseq.uiSession")
        defaults.removeObject(forKey: "logseq.composerDraft")
    }
}
