import UIKit
@testable import Logseq

@main struct FirstContentFrameCheck {
    @MainActor static func main() async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "FirstContentFrame", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }!
        let observer = LogseqFirstContentFrame()
        var callbacks = 0
        observer.observe(in: window) { callbacks += 1 }
        try require(callbacks == 0, "First-frame work must not run synchronously during view construction")
        window.rootViewController?.view.setNeedsLayout()
        for _ in 0..<100 where callbacks == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(callbacks == 1, "The first committed content frame must release deferred work")
        observer.observe(in: window) { callbacks += 1 }
        window.rootViewController?.view.setNeedsLayout()
        try await Task.sleep(for: .milliseconds(50))
        try require(callbacks == 1, "A later appearance must not replay first-frame work")
        print("PASS: native frame observation waits for rendering and releases work exactly once")
    }
}
