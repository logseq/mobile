import SwiftUI
import UIKit
@testable import Logseq
@testable import LUIAppleBackend
import LogseqModel

// Change poses in Device Hub while this runs; the same renderer stays mounted.
// LOGSEQ_DUO_CHECK_SECONDS controls the observation interval (default: 40).
// LOGSEQ_DUO_REQUIRE_POSE_CHANGE=1 requires both toolbar axes to be exercised.
// LOGSEQ_DUO_CHECK_INTERACTIONS=1 also exercises the side capture and search actions.
@main struct DuoToolbarLayoutCheck {
    @MainActor static func main() async throws {
        let resources = Bundle(url: Bundle.main.bundleURL.appendingPathComponent("logseq_Logseq.bundle"))!
        let translationsURL = resources.url(forResource: "CaptureLocalizations", withExtension: "json")!
        let translations = try JSONDecoder().decode([String: [String: String]].self,
                                                     from: Data(contentsOf: translationsURL))
        for (language, entries) in translations {
            for (key, expected) in entries {
                guard CaptureLocalization.text(key, locale: Locale(identifier: language)) == expected else {
                    throw failure("Native capture translation is missing: \(language) \(key)")
                }
            }
        }
        print("PASS: native capture and recording strings cover \(translations.count) languages")
        let snapshot = #"{"ok":true,"result":{"graphName":"Duo layout check","selectedGraphId":"duo-demo","outlinerRows":[{"depth":0,"hasChildren":false,"isCollapsed":false,"block":{"uuid":"duo-note","title":"Fold, unfold, and rotate without leaving this journal.","pageId":"journal"}}]}}"#
        var attachmentRequests: [String] = []
        let platform = LGPlatformEffectHandler(saveSettings: { _ in },
            runtimeLog: LogseqRuntimeLog(capacity: 1), copyText: { _ in }, signOut: {},
            presentAttachment: { service in attachmentRequests.append(service); return true })
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(
            callCore: { _ in snapshot }, platformEffect: { await platform.execute($0) }))
        try runtime.applyCoreResponse(snapshot)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first(where: { $0.windows.contains { $0.isKeyWindow && !$0.isHidden } })
                ?? scenes.first else {
            throw failure("Missing check window scene")
        }
        let window = UIWindow(windowScene: scene)
        if ProcessInfo.processInfo.environment["LOGSEQ_DUO_REGULAR_WIDTH"] == "1" {
            window.traitOverrides.horizontalSizeClass = .regular
        }
        let host = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }

        func node(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
                    && frames[$0].map { !$0.isEmpty && $0.intersects(window.bounds) } == true
            }
        }
        func syncNode() -> Int? {
            ["sync.connected", "sync.disconnected", "sync.failed"].compactMap(node).first
        }

        func saveScreenshot(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(name))
        }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            try saveScreenshot("duo-interaction-failed.png")
            throw failure(message)
        }
        func emit(_ identifier: String, _ event: String) throws {
            guard let id = backend.rootIDs.flatMap(descendants).first(where: {
                backend.extensionModel(id: $0)?.identifier == identifier
            }) else { throw failure("Missing extension " + identifier) }
            try backend.performExtensionEvent(node: id, name: event, values: [:])
        }
        let sideActions = ["button.navigation.camera", "button.navigation.audio", "button.navigation.search", "button.navigation.capture"]
        func sideActionsVisible() -> Bool { sideActions.allSatisfy { node($0) != nil } }
        func focusedComposer() -> UITextView? {
            guard node("field.composer") != nil else { return nil }
            return views(window).compactMap { $0 as? UITextView }.first { $0.isFirstResponder }
        }
        func verifySideInteractions() async throws {
            guard let audio = node("button.navigation.audio") else { throw failure("Missing side recording action") }
            try backend.performPress(node: audio)
            await runtime.drainEffectsForTesting()
            guard attachmentRequests == ["audio"], focusedComposer() == nil else {
                throw failure("The side recording button must open the existing recorder directly")
            }
            guard let capture = node("button.navigation.capture") else { throw failure("Missing side capture action") }
            try backend.performPress(node: capture)
            try await wait("Side capture must focus the native composer and hide the side actions") {
                guard let input = focusedComposer(), sideActions.allSatisfy({ node($0) == nil }) else { return false }
                let inputFrame = input.convert(input.bounds, to: window)
                let keyboardTop = host.view.convert(host.view.keyboardLayoutGuide.layoutFrame, to: window).minY
                return !inputFrame.isEmpty && window.bounds.contains(inputFrame) && inputFrame.maxY <= keyboardTop + 1
            }
            let draft = "Duo native draft 🙂"
            focusedComposer()!.insertText(draft)
            await runtime.drainEffectsForTesting()
            try await wait("Typing in side capture must update the composer") { focusedComposer()?.text == draft }
            try saveScreenshot("duo-side-capture-focused.png")
            try emit("native-navigation-stack", "dismiss-composer")
            try await wait("Dismissing capture must restore the side actions") { sideActionsVisible() && focusedComposer() == nil }
            try backend.performPress(node: node("button.navigation.capture")!)
            try await wait("Reopening side capture must preserve its draft and keyboard focus") { focusedComposer()?.text == draft }
            try emit("native-navigation-stack", "dismiss-composer")
            try await wait("Capture must collapse before searching") { sideActionsVisible() && focusedComposer() == nil }

            try backend.performPress(node: node("button.navigation.search")!)
            try await wait("Side search must focus the native search field and hide side actions") {
                views(window).compactMap { $0 as? UISearchTextField }.contains { $0.isFirstResponder }
                    && sideActions.allSatisfy { node($0) == nil }
            }
            try saveScreenshot("duo-side-search-focused.png")
            try emit("native-search-presentation", "dismiss")
            try await wait("Closing search must restore the side actions and release search focus") {
                sideActionsVisible() && !views(window).compactMap { $0 as? UISearchTextField }.contains { $0.isFirstResponder }
            }
            guard runtime.lastError == nil else { throw failure(runtime.lastError!) }
            print("PASS: side capture focuses above the keyboard, preserves its draft after dismissal, and side search opens and closes with native focus")
        }
        func nativeDiagnostics() -> String {
            let relevant = views(window).compactMap { view -> String? in
                let name = String(describing: type(of: view))
                let identifier = view.accessibilityIdentifier ?? ""
                guard name.contains("Bar") || identifier.hasPrefix("sync.") || identifier == "button.journal-calendar" else { return nil }
                return "\(name) id=\(identifier) frame=\(view.convert(view.bounds, to: window)) hidden=\(view.isHidden) alpha=\(view.alpha)"
            }
            let sceneDetails = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.map { current in
                "role=\(current.session.role.rawValue) state=\(current.activationState.rawValue) bounds=\(current.coordinateSpace.bounds) screen=\(current.screen.bounds) windows=\(current.windows.map { "key=\($0.isKeyWindow) hidden=\($0.isHidden) bounds=\($0.bounds)" })"
            }.joined(separator: "\n")
            return "window=\(window.bounds) screen=\(scene.screen.bounds) host=\(host.view.frame) scene=\(scene.activationState.rawValue) scenes=\n\(sceneDetails)\nnativeViews=\n" + relevant.joined(separator: "\n")
        }
        func nativeControlFrames(vertical: Bool) -> (CGRect, CGRect)? {
            // Hoisted toolbar nodes can lose their shared frame-cache entries
            // when an outgoing SwiftUI copy disappears. Read UIKit's live pair.
            guard let pair = views(window).first(where: { view in
                guard String(describing: type(of: view)).hasPrefix("UIKitBarItemHost"), !view.isHidden else { return false }
                return abs(view.bounds.width - (vertical ? 44 : 88)) < 1
                    && abs(view.bounds.height - (vertical ? 88 : 44)) < 1
            }) else { return nil }
            let first = CGRect(origin: .zero, size: CGSize(width: 44, height: 44))
            let second = first.offsetBy(dx: vertical ? 0 : 44, dy: vertical ? 44 : 0)
            return (pair.convert(first, to: window), pair.convert(second, to: window))
        }

        let seconds = Double(ProcessInfo.processInfo.environment["LOGSEQ_DUO_CHECK_SECONDS"] ?? "40") ?? 40
        let deadline = Date().addingTimeInterval(seconds)
        var previous = ""
        var changedAt = Date()
        var captured: Set<String> = []
        var axes: Set<String> = []
        var lastAvailability = ""
        var lastMissingBounds = CGRect.null
        let checkInteractions = ProcessInfo.processInfo.environment["LOGSEQ_DUO_CHECK_INTERACTIONS"] == "1"
        var interactionsChecked = false
        print("DUO_CHECK_READY: change poses in Device Hub for \(seconds) seconds")
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            let vertical: Bool
            if #available(iOS 27.1, *) {
                vertical = host.view.traitCollection.verticalBarEdge != .unspecified
            } else { vertical = false }
            let reported = syncNode().flatMap { sync in
                node("button.journal-calendar").flatMap { calendar in
                    frames[sync].flatMap { first in frames[calendar].map { (first, $0) } }
                }
            }
            guard let (first, second) = nativeControlFrames(vertical: vertical) ?? reported,
                  first.width > 0, first.height > 0, second.width > 0, second.height > 0 else {
                let relevant = backend.rootIDs.flatMap(descendants).compactMap { id -> String? in
                    guard let identifier = backend.model(id: id)?.property(.accessibilityIdentifier)?.stringValue,
                          identifier.hasPrefix("sync.") || identifier == "button.journal-calendar" else { return nil }
                    return "\(identifier)[\(id)]=\(String(describing: frames[id]))"
                }.joined(separator: " ")
                let availability = "nodes=\(relevant) totalFrames=\(frames.count) bounds=\(window.bounds)"
                if availability != lastAvailability {
                    lastAvailability = availability
                    print("DUO_WAIT \(availability)")
                }
                if lastMissingBounds != window.bounds {
                    lastMissingBounds = window.bounds
                    print("DUO_NATIVE \(nativeDiagnostics())")
                    try saveScreenshot("duo-toolbar-missing-\(Int(window.bounds.width))x\(Int(window.bounds.height)).png")
                }
                continue
            }
            let axis = vertical ? "vertical" : "horizontal"
            let signature = "\(Int(window.bounds.width))x\(Int(window.bounds.height))-\(axis)-\(Int(first.minX)),\(Int(first.minY))-\(Int(second.minX)),\(Int(second.minY))"
            if previous != signature {
                previous = signature
                changedAt = Date()
                continue
            }
            guard Date().timeIntervalSince(changedAt) > 0.6, !captured.contains(signature) else { continue }
            let bounds = window.bounds.insetBy(dx: -1, dy: -1)
            guard bounds.contains(first), bounds.contains(second), !first.insetBy(dx: 1, dy: 1).intersects(second.insetBy(dx: 1, dy: 1)) else {
                throw failure("Toolbar targets must be inside the window and separate: bounds=\(window.bounds) sync=\(first) calendar=\(second)")
            }
            let aligned = vertical
                ? abs(first.midX - second.midX) < 2 && abs(first.midY - second.midY) >= 40
                : abs(first.midY - second.midY) < 2 && abs(first.midX - second.midX) >= 40
            guard aligned else {
                throw failure("Toolbar controls must follow the actual \(axis) bar: sync=\(first) calendar=\(second)")
            }
            let actionIdentifiers = vertical
                ? sideActions
                : ["button.composer.camera", "button.composer.expand", "button.search"]
            let actionFrames = actionIdentifiers.compactMap { identifier in node(identifier).flatMap { frames[$0] } }
            guard actionFrames.count == actionIdentifiers.count, actionFrames.allSatisfy({
                bounds.contains($0) && $0.width >= 44 && $0.height >= 44
            }) else {
                throw failure("Capture actions must have visible 44pt targets in the \(axis) layout: \(actionFrames)")
            }
            for index in 0..<actionFrames.count {
                for other in (index + 1)..<actionFrames.count {
                    guard !actionFrames[index].insetBy(dx: 1, dy: 1).intersects(actionFrames[other].insetBy(dx: 1, dy: 1)) else {
                        throw failure("Capture actions overlap: \(actionFrames)")
                    }
                }
            }
            if vertical {
                guard actionFrames.allSatisfy({ abs($0.midX - first.midX) < 2 }) else {
                    try saveScreenshot("duo-rail-misaligned.png")
                    throw failure("Capture rail must align with the native side controls: sync=\(first), actions=\(actionFrames), safeArea=\(host.view.safeAreaInsets)")
                }
                guard let last = actionFrames.last,
                      window.bounds.maxY - last.maxY <= max(44, window.safeAreaInsets.bottom + 10) else {
                    throw failure("Capture rail must stay near the bottom edge, without a duplicate safe-area inset: \(actionFrames)")
                }
                guard let rail = views(window).first(where: { $0.accessibilityIdentifier == "navigation.capture-rail" }),
                      actionFrames.allSatisfy({ frame in
                          window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)?.isDescendant(of: rail) == true
                      }) else {
                    throw failure("The visible side actions must receive touches at their rendered positions")
                }
                guard actionFrames.allSatisfy({ abs($0.midX - actionFrames[0].midX) < 2 }),
                      zip(actionFrames, actionFrames.dropFirst()).allSatisfy({ pair in pair.0.minY < pair.1.minY }),
                      node("button.composer.expand") == nil else {
                    throw failure("Vertical capture actions must share the side rail and replace the bottom capsule")
                }
            }
            captured.insert(signature)
            axes.insert(axis)
            try saveScreenshot("duo-toolbar-\(captured.count)-\(axis).png")
            print("DUO_LAYOUT axis=\(axis) bounds=\(window.bounds) safeArea=\(host.view.safeAreaInsets) sync=\(first) calendar=\(second) captureActions=\(actionFrames)")
            if vertical && checkInteractions && !interactionsChecked {
                try await verifySideInteractions()
                interactionsChecked = true
            }
        }
        guard !captured.isEmpty else {
            print("DUO_NATIVE_FINAL \(nativeDiagnostics())")
            try saveScreenshot("duo-toolbar-missing-final.png")
            throw failure("No stable toolbar frames were reported")
        }
        if ProcessInfo.processInfo.environment["LOGSEQ_DUO_REQUIRE_POSE_CHANGE"] == "1", axes.count != 2 {
            throw failure("Exercise both horizontal and vertical bars in Device Hub; observed \(axes)")
        }
        if checkInteractions && !interactionsChecked {
            throw failure("Side action interactions require a stable vertical toolbar layout")
        }
        print("PASS: native toolbar controls stay separate, visible, and aligned across \(captured.count) stable layouts; axes=\(axes.sorted())")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "DuoToolbarLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
