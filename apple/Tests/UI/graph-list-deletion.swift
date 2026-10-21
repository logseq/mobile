import UIKit
import SwiftUI
import LUIAppleBackend

@main struct GraphListDeletionCheck {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(GraphListDeletionDelegate.self))
    }
}

@MainActor final class GraphListDeletionDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task {
            do { try await run() }
            catch { finish("FAIL: \(error)") }
        }
        return true
    }
    func finish(_ output: String) {
        try? output.write(to: URL.documentsDirectory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }
    func run() async throws {
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf:
            Bundle.main.url(forResource: "graph-list-deletion-patches", withExtension: "json")!)) as! [[String: Any]]
        for cycle in 0..<24 {
            let backend = LUIAppleBackend()
            backend.coalescesCommits = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            self.window = window
            for (index, batch) in fixtures.enumerated() {
                var replay = batch
                if index > 0 { replay["generation"] = index + 2 }
                if index == 1, let ops = replay["ops"] as? [[String: Any]] {
                    replay["ops"] = ops.filter { $0["id"] as? Int != 73 }
                }
                let data = try JSONSerialization.data(withJSONObject: replay)
                try backend.apply(json: String(decoding: data, as: UTF8.self))
                if index == 0 {
                    window.rootViewController = UIHostingController(rootView: LUISwiftUIRoot(backend: backend, rootID: 1))
                    window.makeKeyAndVisible()
                }
                try await Task.sleep(for: .milliseconds(index == 0 ? 220 : cycle % 4 * 30))
                if index == 0 {
                    func collection(_ view: UIView) -> UICollectionView? {
                        (view as? UICollectionView) ?? view.subviews.compactMap(collection).first
                    }
                    guard let list = collection(window), let cell = list.cellForItem(at: IndexPath(item: 0, section: 1)) else {
                        finish("FAIL: local graph row is missing"); return
                    }
                    let content = cell.contentView.subviews.first
                    let patch: [String: Any] = ["generation":2,"ops":[["op":"remove-child","parent":72,"child":73], ["op":"detach-subtree","id":73]]]
                    try backend.apply(json: String(decoding: JSONSerialization.data(withJSONObject: patch), as: UTF8.self))
                    try await Task.sleep(for: .milliseconds(200))
                    guard let after = list.cellForItem(at: IndexPath(item: 0, section: 1)),
                          after === cell, after.contentView.subviews.first === content else {
                        finish("FAIL: removing the last context action replaced a retained native row"); return
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(230))
            window.layoutIfNeeded()
            func collection(_ view: UIView) -> UICollectionView? {
                (view as? UICollectionView) ?? view.subviews.compactMap(collection).first
            }
            guard let list = collection(window), list.numberOfSections == 3,
                  (0..<3).map({ list.numberOfItems(inSection: $0) }) == [2, 1, 2] else {
                finish("FAIL: deletion did not move the graph from Local to Remote exactly once"); return
            }
            window.isHidden = true
        }
        finish("PASS: 24 native grouped-list deletions preserved valid row counts")
    }
}
