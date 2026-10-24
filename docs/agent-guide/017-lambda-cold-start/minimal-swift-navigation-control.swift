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
    static var mode: String { ProcessInfo.processInfo.environment["LOGSEQ_FRAME_CONTROL_MODE"] ?? "plain" }
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
        print("RUNTIME_CHECK_COMPLETE")
        exit(0)
    }
}

struct NavigationControl: View {
    @State private var path: [Int] = []
    var body: some View {
        switch Timing.mode {
        case "navigation":
            AnyView(NavigationStack(path: $path) {
                ContentView().navigationDestination(for: Int.self) { value in Text("Destination \(value)") }
            })
        case "toolbar":
            AnyView(NavigationStack(path: $path) {
                ContentView()
                    .navigationDestination(for: Int.self) { value in Text("Destination \(value)") }
                    .navigationTitle("Journals")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("Menu") { } }
                        ToolbarItem(placement: .topBarTrailing) { Button("Next") { path.append(1) } }
                    }
            })
        default:
            AnyView(ContentView())
        }
    }
}

struct ControlApp: App {
    var body: some Scene { WindowGroup { NavigationControl() } }
}

@main @MainActor enum Entry {
    static func main() {
        setbuf(stdout, nil)
        _ = Timing.birth
        Timing.mark("main_entry")
        Probe.shared.observe()
        ControlApp.main()
    }
}
