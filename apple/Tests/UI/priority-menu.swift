import SwiftUI
import UIKit
import Vision
@testable import Logseq
@testable import LUIAppleBackend

@MainActor private final class PriorityEffects: LGEffectExecuting {
    var choices: [String] = []
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "set-outliner-task-priority" { choices.append(effect.metadata ?? "") }
        return LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct PriorityMenuCheck {
    @MainActor static func main() async throws {
        let choices: [[String: Any]] = [
            ["uuid": "low", "title": "Low", "icon": "app:priority-low"],
            ["uuid": "urgent", "title": "Urgent", "icon": "app:priority-urgent"],
            ["uuid": "custom", "title": "Critical", "icon": "app:priority-high"]
        ]
        var payload: [String: Any] = [
            "uuid": "task", "title": "Task priority", "markup": [], "depth": 0,
            "hasChildren": false, "collapsed": false, "isAsset": false, "assetType": "",
            "localPath": "", "youtubeURL": "", "completed": false, "selected": false,
            "opensAsPage": false, "journalBullet": false, "syncFailed": false,
            "status": ["uuid": "todo", "title": "Todo", "icon": "app:task-todo"],
            "statuses": [], "priority": choices[0], "priorities": choices, "tags": []
        ]
        func row() throws -> OutlinerRowPayload {
            try JSONDecoder().decode(OutlinerRowPayload.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        var events: [(String, [String: LUIExtensionValue])] = []
        let native = OutlinerTextRowView()
        func update() throws { native.update(try row(), emit: { name, _, values in events.append((name, values)) }) }
        try update()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        controller.view.addSubview(native)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        native.frame = CGRect(x: 16, y: 150, width: window.bounds.width - 32, height: 60)
        native.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        guard let button = native.subviews.first(where: { $0.accessibilityIdentifier == "button.block-task-priority" }) as? UIButton else {
            throw failure("Priority must be a native menu button, not an inert image")
        }
        guard button.showsMenuAsPrimaryAction, let menu = button.menu else {
            throw failure("Tapping the priority button must open a native popup")
        }
        let actions = menu.children.compactMap { $0 as? UIAction }
        guard actions.map(\.title) == ["Low", "Urgent", "Critical", "Clear priority"],
              actions[0].state == .on, actions[1].state == .off else {
            throw failure("Priority menu must preserve graph choices and check the current value")
        }
        if #available(iOS 17.4, *) { button.performPrimaryAction() }
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("priority-popup.png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
        let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        guard visible.contains("Urgent") && visible.contains("Critical") else {
            throw failure("The native popup must actually be visible: \(visible)")
        }
        button.contextMenuInteraction?.dismissMenu()
        try await Task.sleep(for: .milliseconds(200))
        guard events.isEmpty else { throw failure("Dismissing a priority menu must not mutate the block") }
        // Invoke the real menu action through UIKit's public target/action API.
        let actionControl = UIControl()
        actionControl.addAction(actions[2], for: .primaryActionTriggered)
        actionControl.sendActions(for: .primaryActionTriggered)
        guard events.count == 1, events[0].0 == "set-priority", events[0].1["priority"] == .string("custom") else {
            throw failure("A custom choice must emit its stable UUID")
        }
        payload["priority"] = choices[2]
        try update()
        let updated = button.menu!.children.compactMap { $0 as? UIAction }
        guard updated[2].state == .on, updated[0].state == .off else { throw failure("A retained row must refresh its checked priority") }
        actionControl.addAction(updated[3], for: .touchUpInside)
        actionControl.sendActions(for: .touchUpInside)
        guard events.count == 2, events[1].1["priority"] == .string("") else { throw failure("Clear priority must emit an explicit empty selection") }
        payload.removeValue(forKey: "priority")
        try update()
        guard button.isHidden, button.menu == nil else { throw failure("Reused rows must clear stale priority menus") }
        let effects = PriorityEffects()
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        let snapshot: [String: Any] = ["ok": true, "result": [
            "selectedGraphId": "priority", "graphName": "Priority regression",
            "taskPriorities": [["uuid": "custom", "title": "Critical"]],
            "outlinerRows": [["depth": 0, "block": ["uuid": "task", "title": "Task priority",
                "pageId": "page", "priority": ["uuid": "custom", "title": "Critical"]]]]
        ]]
        try runtime.applyCoreResponse(String(decoding: JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        defer { runtime.stop() }
        try await Task.sleep(for: .milliseconds(400))
        func buttons(_ view: UIView) -> [UIButton] {
            ((view as? UIButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
        }
        guard let rendered = buttons(window.rootViewController!.view).first(where: {
            $0.accessibilityIdentifier == "button.block-task-priority"
        }), let choice = rendered.menu?.children.first as? UIAction else {
            throw failure("The shared runtime must mount the native priority menu")
        }
        actionControl.addAction(choice, for: .touchDown)
        actionControl.sendActions(for: .touchDown)
        for _ in 0..<100 {
            if !effects.choices.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard effects.choices.count == 1,
              let data = effects.choices[0].data(using: .utf8),
              let selected = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              selected["uuid"] as? String == "custom", runtime.lastError == nil else {
            throw failure("A native menu selection must survive the complete extension and effect bridge")
        }
        print("PASS: native priority popup visibly opens, selects custom values, checks current selection, cancels, clears, and resets reused rows")
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PriorityMenuCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
