import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class PropertyActionEffects: LGEffectExecuting {
    var requests: [[String: Any]] = []
    var reject = false
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "node-property", let data = effect.text.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            requests.append(payload)
            return .init(succeeded: !reject, message: reject ? "Storage unavailable" : "", output: .discard)
        }
        return .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct PagePropertyActionsCheck {
    @MainActor static func main() async throws {
        let effects = PropertyActionEffects()
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        let snapshot: [String: Any] = ["ok": true, "result": [
            "selectedGraphId": "property-actions", "graphName": "Property actions",
            "selectedPage": ["uuid": "page", "title": "Project notes"], "outlinerRows": [],
            "nodeProperties": ["ownerUuid": "page", "canAdd": true, "properties": [],
                "availableProperties": [["attr": "user.property/Notes", "title": "Notes"]]]]]
        try runtime.applyCoreResponse(String(decoding: JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func failure(_ message: String) -> NSError {
            NSError(domain: "PagePropertyActions", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            print("PROPERTY_UI_ERROR=\(runtime.lastError ?? "none")")
            print("PROPERTY_UI_IDS=\(backend.rootIDs.flatMap(descendants).compactMap { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue })")
            throw failure(message)
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer).tint(LogseqThemePolicy.accent))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        let add = "property.add.page"
        func press(_ identifier: String) throws {
            guard let node = find(identifier) else { throw failure("Missing action: " + identifier) }
            try backend.performPress(node: node)
        }
        func capture(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(400))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(name))
        }
        try await wait("An empty page offers Add property in More") { find(add) != nil && find("button.connection") != nil && frames[find("button.connection")!] != nil }
        guard descendants(find("button.connection")!).contains(find(add)!) else { throw failure("Add property must belong to More") }
        guard find("properties.page") == nil else { throw failure("An empty page must keep its reading content clear") }
        guard frames[find("button.connection")!]!.height >= 44 else { throw failure("More needs a 44-point target") }
        var filled = snapshot
        var result = snapshot["result"] as! [String: Any]
        var properties = result["nodeProperties"] as! [String: Any]
        properties["properties"] = [["attr": "user.property/Related", "title": "Related", "kind": "node",
            "editable": true, "references": [["uuid": "target", "title": "Target page"]]]]
        result["nodeProperties"] = properties
        filled["result"] = result
        try runtime.applyCoreResponse(String(decoding: JSONSerialization.data(withJSONObject: filled), as: UTF8.self))
        try await wait("Reference context actions are mounted") { find("property.edit.page.user.property/Related.target") != nil }
        guard find("property.value.page.user.property/Related") == nil,
              find("property.edit.page.user.property/Related.target") != nil else { throw failure("References use context editing without a permanent Edit button") }
        for identifier in ["property.open.page.user.property/Related.target"] {
            try await wait("Node navigation and editing must be laid out") { find(identifier) != nil && frames[find(identifier)!] != nil }
            guard frames[find(identifier)!]!.height >= 44 else { throw failure("Node actions need 44-point targets") }
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(400))
            let started = CFAbsoluteTimeGetCurrent()
            try press(add)
            let dispatchElapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
            guard dispatchElapsed < 100 else { throw failure("Local property action took \(dispatchElapsed) ms") }
            print("PROPERTY_PRESS_MS=\(dispatchElapsed)")
            try await wait("The local property catalog must appear immediately") { find(add + ".search") != nil }
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
            print("PROPERTY_CATALOG_READY_MS=\(elapsed)")
            try await wait("A native sheet must be presented") { window.rootViewController?.presentedViewController != nil }
            try await capture("add-property-\(style == .dark ? "dark" : "light").png")
            try press(add + ".cancel")
            try await wait("Cancel dismisses the sheet") { window.rootViewController?.presentedViewController == nil }
        }
        guard effects.requests.isEmpty else { throw failure("Browsing and cancelling must not write") }
        try press(add)
        try await wait("Catalog can reopen") { find("property.add.option.page.user.property/Notes") != nil }
        try backend.performTextChange(node: find(add + ".search")!, text: "Notes")
        guard find(add + ".create") == nil else { throw failure("Existing names must not offer duplicate creation") }
        try press("property.add.option.page.user.property/Notes")
        try await wait("Selecting a property submits once and dismisses") { effects.requests.count == 1 && find(add + ".sheet") == nil }
        guard effects.requests[0]["action"] as? String == "add",
              effects.requests[0]["blockUuid"] as? String == "page" else { throw failure("Wrong property target") }
        try await wait("Native dismissal finishes") { window.rootViewController?.presentedViewController == nil }
        effects.reject = true
        try press(add)
        try await wait("Search is available") { find(add + ".search") != nil }
        try backend.performTextChange(node: find(add + ".search")!, text: "Reading notes")
        try await wait("A new name offers explicit creation") { find(add + ".create") != nil }
        guard find("property.add.option.page.user.property/Notes") == nil else { throw failure("Search must filter locally") }
        try press(add + ".create")
        try await wait("Failed creation stays in the sheet") { effects.requests.count == 2 && find("view.action.error." + add) != nil }
        guard backend.model(id: find(add + ".search")!)?.property(.text)?.stringValue == "Reading notes" else {
            throw failure("A failed creation must keep its draft")
        }
        try await capture("add-property-failure.png")
        try press(add + ".cancel")
        print("PASS: native property sheets, local search, 44-point action, light/dark layout, cancel, submit and failure retry")
    }
}
