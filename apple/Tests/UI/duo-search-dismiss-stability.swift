import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class SearchJournalSampler: NSObject {
    let scroll: UIScrollView
    let window: UIWindow
    private var displayLink: CADisplayLink?
    private(set) var samples: [(top: CGFloat, offset: CGFloat)] = []

    init(scroll: UIScrollView, window: UIWindow) {
        self.scroll = scroll
        self.window = window
        super.init()
        displayLink = CADisplayLink(target: self, selector: #selector(sample))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func sample() {
        samples.append((scroll.convert(scroll.bounds, to: window).minY, scroll.contentOffset.y))
    }
    func clear() { samples.removeAll(keepingCapacity: true) }
    func stop() { displayLink?.invalidate(); displayLink = nil }
}

@main struct DuoSearchDismissStabilityCheck {
    @MainActor static func main() async throws {
        var query = ""
        func snapshot() -> String {
            let rows: [[String: Any]] = (0..<96).map { index in
                ["depth": 0, "block": ["uuid": "row-\(index)",
                    "title": "Retained journal row \(index)", "pageId": "journal"]]
            }
            return String(decoding: try! JSONSerialization.data(withJSONObject: ["ok": true, "result": [
                "graphName": "Search stability", "selectedGraphId": "search-stability",
                "outlinerRows": rows, "searchQuery": query,
                "searchResults": query.isEmpty ? [] : [["uuid": "result", "title": "Result", "isPage": true]],
            ]]), as: UTF8.self)
        }
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { request in
            if let data = request.params.payload?.data(using: .utf8),
               let effect = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               effect["kind"] as? String == "search" {
                query = effect["text"] as? String ?? ""
            }
            return snapshot()
        }))
        try runtime.applyCoreResponse(snapshot())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            throw failure("Missing simulator window scene")
        }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func wait(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<150 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure(message)
        }
        var scroll: UIScrollView?
        try await wait("Journal must mount") {
            scroll = views(window).compactMap { $0 as? UIScrollView }.first {
                $0.contentSize.height > $0.bounds.height * 2 && $0.bounds.width > 100
            }
            return scroll != nil
        }
        let journal = scroll!
        try await Task.sleep(for: .milliseconds(600))
        journal.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        try await Task.sleep(for: .milliseconds(300))
        let baselineTop = journal.convert(journal.bounds, to: window).minY
        let baselineOffset = journal.contentOffset.y
        let sampler = SearchJournalSampler(scroll: journal, window: window)
        defer { sampler.stop() }
        let searchID = backend.rootIDs.flatMap(descendants).first {
            backend.extensionModel(id: $0)?.identifier == "native-search-presentation"
        }!
        for initialQuery in ["", "Needle", ""] {
            try backend.performExtensionEvent(node: searchID, name: "present", values: [:])
            try await wait("Native search must take focus") {
                views(window).compactMap { $0 as? UISearchTextField }.contains { $0.isFirstResponder }
            }
            let field = views(window).compactMap { $0 as? UISearchTextField }.first { $0.isFirstResponder }!
            if !initialQuery.isEmpty { field.insertText(initialQuery) }
            try await Task.sleep(for: .milliseconds(500))
            let fieldFrame = field.convert(field.bounds, to: window)
            guard let cancel = views(window).compactMap({ $0 as? UIControl }).first(where: { control in
                let frame = control.convert(control.bounds, to: window)
                guard frame.minX >= fieldFrame.maxX - 1, abs(frame.midY - fieldFrame.midY) < 24,
                      frame.width >= 20, frame.height >= 20, control.isEnabled, !control.isHidden,
                      let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) else { return false }
                return hit === control || hit.isDescendant(of: control)
            }) else { throw failure("Native search Cancel must be tappable") }
            sampler.clear()
            cancel.sendActions(for: cancel.allControlEvents.contains(.primaryActionTriggered) ? .primaryActionTriggered : .touchUpInside)
            try await Task.sleep(for: .milliseconds(800))
            let topShift = sampler.samples.map { abs($0.top - baselineTop) }.max() ?? .infinity
            let offsetShift = sampler.samples.map { abs($0.offset - baselineOffset) }.max() ?? .infinity
            print("SEARCH_CANCEL query=\(initialQuery) samples=\(sampler.samples.count) topShift=\(topShift) offsetShift=\(offsetShift)")
            guard sampler.samples.count > 5, topShift < 1, offsetShift < 1,
                  views(window).contains(where: { $0 === journal }) else {
                throw failure("Native Cancel must retain the journal position throughout dismissal: top=\(topShift), scroll=\(offsetShift)")
            }
        }
        print("PASS: repeated native Cancel preserves journal identity, position and scroll on every display frame")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "DuoSearchDismissStability", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
