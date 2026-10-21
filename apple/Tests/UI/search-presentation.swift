import UIKit
import SwiftUI
import OSLog
import LUIAppleBackend

let logger = Logger(subsystem: "com.logseq.logseq.tests", category: "Search")

@MainActor private final class SearchFocusEvents: NSObject {
    var begins = 0
    var ends = 0
    var keyboardTop: CGFloat?
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(began), name: UITextField.textDidBeginEditingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(ended), name: UITextField.textDidEndEditingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
    @objc private func began(_ note: Notification) { if note.object is UISearchTextField { begins += 1 } }
    @objc private func ended(_ note: Notification) { if note.object is UISearchTextField { ends += 1 } }
    @objc private func keyboardChanged(_ note: Notification) {
        guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let frame = value.cgRectValue
        keyboardTop = frame.height > 0 ? frame.minY : nil
    }
    func reset() { begins = 0; ends = 0 }
    deinit { NotificationCenter.default.removeObserver(self) }
}

@main struct SearchPresentationCheck {
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(SearchCheckDelegate.self)) }
}

@MainActor private final class SearchCheckHost<Content: View>: UIHostingController<Content> {
    private(set) var appeared = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
    }
}

@MainActor final class SearchCheckDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { @MainActor in
            do { try await run() }
            catch { finish("FAIL: \(error)") }
        }
        return true
    }
    private func finish(_ output: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.txt")
        try? output.write(to: url, atomically: true, encoding: .utf8)
    }
    func run() async throws {
        let registry = LUIAppleExtensionRegistry()
        try LGSearchPresentationExtension.register(in: registry)
        let backend = try LUIAppleBackend(extensionRegistry: registry)
        var generation = 1
        try backend.apply(json: """
        {"generation":1,"ops":[
          {"op":"create-extension","id":1,"identifier":"native-search-presentation","fingerprint":"\(LGSearchPresentationExtension.fingerprint)"},
          {"op":"set-extension-prop","id":1,"property":"presented","value":false},
          {"op":"set-extension-prop","id":1,"property":"bottom-occupies-layout-space","value":false},
          {"op":"set-extension-prop","id":1,"property":"depth","value":0},
          {"op":"set-extension-prop","id":1,"property":"query","value":""},
          {"op":"set-extension-prop","id":1,"property":"title","value":"Search"},
          {"op":"create-node","id":2,"kind":"column"},
          {"op":"set-prop","id":2,"property":"grow","value":1.0},
          {"op":"set-prop","id":2,"property":"background","value":"#ff0000"},
          {"op":"create-node","id":3,"kind":"column"},
          {"op":"set-prop","id":3,"property":"grow","value":1.0},
          {"op":"set-prop","id":3,"property":"background","value":"#ffffff"},
          {"op":"insert-child","parent":1,"child":2,"index":0},
          {"op":"insert-child","parent":1,"child":3,"index":1}
        ]}
        """)
        var delayedQueries: [String]?
        func applyQuery(_ query: String) {
            generation += 1
            let encoded = String(decoding: try! JSONEncoder().encode(query), as: UTF8.self)
            try! backend.apply(json: """
            {"generation":\(generation),"ops":[{"op":"set-extension-prop","id":1,"property":"query","value":\(encoded)}]}
            """)
        }
        backend.onEvent = { event in
            guard case .extension(let node, _, let name, let values) = event,
                  node == 1, name == "query-changed",
                  case .string(let query) = values["query"] else { return }
            if delayedQueries != nil { delayedQueries?.append(query) }
            else { applyQuery(query) }
        }
        let host = SearchCheckHost(rootView: NavigationStack {
            LUISwiftUIRoot(backend: backend, rootID: 1)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Text("Journals") } }
        })
        let window = UIWindow(frame: CGRect(x:0,y:0,width:402,height:874))
        self.window = window
        window.rootViewController = host; window.makeKeyAndVisible()
        func step() async { try? await Task.sleep(for: .milliseconds(5)) }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func input() -> UISearchTextField? {
            descendants(window).compactMap { $0 as? UISearchTextField }.first { $0.isFirstResponder }
        }
        let activationStart = ProcessInfo.processInfo.systemUptime
        while (UIApplication.shared.applicationState != .active || !host.appeared)
            && ProcessInfo.processInfo.systemUptime - activationStart < 5 {
            await step()
        }
        guard UIApplication.shared.applicationState == .active, host.appeared else {
            finish("FAIL: the search fixture did not become visible")
            return
        }
        // Measure UIKit's cold keyboard startup separately from search presentation.
        let baseline = UITextField(frame: CGRect(x: 20, y: 200, width: 300, height: 44))
        baseline.placeholder = "Native keyboard baseline"
        host.view.addSubview(baseline)
        let keyboardStart = ProcessInfo.processInfo.systemUptime
        baseline.becomeFirstResponder()
        baseline.insertText("UIKit")
        guard baseline.text == "UIKit" else { finish("FAIL: native keyboard baseline cannot accept input"); return }
        let coldKeyboardMilliseconds = Int((ProcessInfo.processInfo.systemUptime - keyboardStart) * 1000)
        baseline.resignFirstResponder()
        baseline.removeFromSuperview()
        for _ in 0..<120 { await step() }
        let focus = SearchFocusEvents()
        func present(_ value: Bool) throws {
            generation += 1
            try backend.apply(json: """
            {"generation":\(generation),"ops":[{"op":"set-extension-prop","id":1,"property":"query","value":""},{"op":"set-extension-prop","id":1,"property":"presented","value":\(value)}]}
            """)
        }
        var failures = 0
        var output: [String] = ["Native keyboard responder setup: \(coldKeyboardMilliseconds) ms"]
        func record(_ message: String) { output.append(message); print(message) }
        for cycle in 0..<3 {
            focus.reset()
            let start = ProcessInfo.processInfo.systemUptime
            try present(true)
            while input() == nil && ProcessInfo.processInfo.systemUptime - start < 2 { await step() }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            // The system toolbar activates search through its own opening transition.
            // Once ready, typing must never recreate or resign the input responder.
            let readyBegins = focus.begins
            let readyEnds = focus.ends
            record("Search cycle \(cycle + 1): input ready after \(Int(elapsed * 1000)) ms")
            if input() == nil || elapsed > (cycle == 0 ? 1.5 : 0.8) {
                record("FAIL: search should accept typing while its presentation animates")
                failures += 1
            }
            if window.rootViewController?.presentedViewController == nil {
                record("FAIL: search navigation must be isolated from the app navigation")
                failures += 1
            }
            input()?.insertText("Fixture")
            if input()?.text != "Fixture" { record("FAIL: first typed characters are lost"); failures += 1 }
            delayedQueries = []
            input()?.insertText(" 中文😀")
            input()?.insertText(" tail")
            let expectedText = "Fixture 中文😀 tail"
            for query in delayedQueries ?? [] {
                applyQuery(query)
                await step()
                if input()?.text != expectedText {
                    record("FAIL: delayed core acknowledgements overwrite newer native typing")
                    failures += 1
                }
            }
            delayedQueries = nil
            // Finish the transition before exercising dismissal and a fresh presentation.
            for _ in 0..<120 { await step() }
            if let field = input() {
                window.layoutIfNeeded()
                func hasActiveSystemSearch(_ controller: UIViewController) -> Bool {
                    if controller.navigationItem.searchController?.isActive == true { return true }
                    if controller.children.contains(where: hasActiveSystemSearch) { return true }
                    return controller.presentedViewController.map(hasActiveSystemSearch) ?? false
                }
                if window.rootViewController.map(hasActiveSystemSearch) != true {
                    record("FAIL: search must use the system search bar and its native cancel control")
                    failures += 1
                }
                let frame = field.convert(field.bounds, to: window)
                let viewportBottom = min(window.bounds.maxY - window.safeAreaInsets.bottom, focus.keyboardTop ?? window.bounds.maxY)
                let gap = viewportBottom - frame.maxY
                // UIKit transforms can round the allowed one-point edge to -1.0000000001.
                // UIKit reserves its own cancel control and glass insets; the field must fit the viewport.
                if gap < -1.01 || gap > 32 || frame.minX < -1 || frame.maxX > window.bounds.maxX + 1 {
                    record("FAIL: search field must stay above the keyboard at the bottom of the viewport; frame=\(frame) viewportBottom=\(viewportBottom)")
                    failures += 1
                }
            }
            if focus.begins != readyBegins || focus.ends != readyEnds {
                record("FAIL: search must retain its responder while typing; begins=\(focus.begins) ends=\(focus.ends)")
                failures += 1
            }
            try present(false)
            let closeStart = ProcessInfo.processInfo.systemUptime
            while input() != nil && ProcessInfo.processInfo.systemUptime - closeStart < 2 { await step() }
            if input() != nil { record("FAIL: search did not dismiss"); failures += 1 }
            for _ in 0..<30 { await step() }
        }
        if failures == 0 { record("PASS: search opens ready for input, preserves typing, and reopens after dismissal") }
        finish(output.joined(separator: "\n"))
    }
}
