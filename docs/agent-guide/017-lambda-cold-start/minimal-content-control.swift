import UIKit
import SwiftUI
import QuartzCore
import Darwin

@MainActor enum Timing {
    static var stages: [String: Double] = [:]
    static let birth: Double = {
        var p = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        precondition(sysctl(&mib, u_int(mib.count), &p, &size, nil, 0) == 0)
        return CACurrentMediaTime() - (Date().timeIntervalSince1970
            - Double(p.kp_proc.p_starttime.tv_sec) - Double(p.kp_proc.p_starttime.tv_usec) / 1_000_000)
    }()
    static func mark(_ name: String) { stages[name] = (CACurrentMediaTime() - birth) * 1_000 }
    static var mode: String { ProcessInfo.processInfo.environment["LOGSEQ_FRAME_CONTROL_MODE"] ?? "uikit" }
}

@MainActor final class NativeContentLabel: UILabel {
    var wasDrawn = false
    override func drawText(in rect: CGRect) { super.drawText(in: rect); wasDrawn = true }
    convenience init(index: Int) {
        self.init(frame: .zero)
        text = "Journal content row \(index + 1)"
        font = .preferredFont(forTextStyle: .body)
        textColor = .label
        numberOfLines = 1
        accessibilityIdentifier = "control.title.\(index)"
    }
}

@MainActor final class ContentController: UIViewController {
    let labels = (0..<5).map { NativeContentLabel(index: $0) }
    override func loadView() {
        let root = UIView(); root.backgroundColor = .systemBackground
        labels.forEach(root.addSubview)
        view = root
        Timing.mark("native_content_created")
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for (index, label) in labels.enumerated() {
            label.frame = CGRect(x: 24, y: view.safeAreaInsets.top + 32 + CGFloat(index * 40), width: view.bounds.width - 48, height: 36)
        }
    }
}

struct NativeLabel: UIViewRepresentable {
    let index: Int
    func makeUIView(context: Context) -> NativeContentLabel { NativeContentLabel(index: index) }
    func updateUIView(_ view: NativeContentLabel, context: Context) { }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<5) { index in NativeLabel(index: index).frame(height: 36) }
            Spacer()
        }.padding(.horizontal, 24).padding(.top, 32)
    }
}

@MainActor final class Probe: NSObject {
    static let shared = Probe()
    var notification: (any NSObjectProtocol)?
    var updates: AnyObject?
    var display: CADisplayLink?
    var presentation: Double?
    var committedTitles = 0
    func observe() {
        notification = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { event in
            MainActor.assumeIsolated {
                guard let window = event.object as? UIWindow, window.windowScene != nil,
                    window.rootViewController != nil, self.updates == nil else { return }
                Timing.mark("window_became_key")
                self.start(window)
            }
        }
    }
    func start(_ window: UIWindow) {
        guard #available(iOS 18.0, *), let scene = window.windowScene else { fatalError("Requires iOS 18") }
        let update = UIUpdateLink(windowScene: scene)
        update.addAction(to: .afterCATransactionCommit) { [weak self] update, info in
            guard let self else { return }
            @MainActor func count(_ view: UIView) -> Int {
                guard !view.isHidden, view.alpha > 0.01 else { return 0 }
                let own: Int
                if let label = view as? NativeContentLabel, label.wasDrawn,
                    !(label.text ?? "").isEmpty, !label.convert(label.bounds, to: window).intersection(window.bounds).isEmpty { own = 1 }
                else { own = 0 }
                return own + view.subviews.reduce(0) { $0 + count($1) }
            }
            let titles = count(window)
            guard titles == 5 else { return }
            Timing.mark("first_commit")
            self.committedTitles = titles
            self.presentation = max(CACurrentMediaTime(), info.estimatedPresentationTime)
            update.isEnabled = false
        }
        self.updates = update; update.isEnabled = true
        let display = CADisplayLink(target: self, selector: #selector(tick))
        display.add(to: .main, forMode: .common); self.display = display
    }
    @objc func tick() {
        guard let presentation, let display, display.timestamp >= presentation else { return }
        display.invalidate()
        Timing.mark("first_display_after_commit")
        let result: [String: Any] = ["mode": Timing.mode, "stages_ms": Timing.stages, "nonempty_drawn_titles": committedTitles]
        print("MINIMAL_FRAME_RESULT " + String(decoding: try! JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
        exit(0)
    }
}

@MainActor final class ApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Timing.mark("delegate_launch"); return true
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Control", sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

@MainActor final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        Timing.mark("scene_connect")
        let window = UIWindow(windowScene: scene)
        if Timing.mode == "hosted" { window.rootViewController = UIHostingController(rootView: ContentView()) }
        else { window.rootViewController = ContentController() }
        self.window = window
        window.makeKeyAndVisible()
    }
}

struct ControlApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

@main @MainActor enum Entry {
    static func main() {
        setbuf(stdout, nil)
        _ = Timing.birth
        Timing.mark("main_entry")
        Probe.shared.observe()
        if Timing.mode == "swiftui" { ControlApp.main() }
        else { _ = UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ApplicationDelegate.self)) }
    }
}
