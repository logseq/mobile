import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class TagPropertyEffects: LGEffectExecuting {
    var requests: [[String: Any]] = []
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "node-property", let data = effect.text.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            requests.append(payload)
        }
        return .init(succeeded: true, message: "", output: .discard)
    }
}

@main struct TagPropertyActionsCheck {
    @MainActor static func main() async throws {
        let effects = TagPropertyEffects()
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        let options = (0..<500).map { ["title": String(format: "PerfTag%03d", $0),
            "match": ["tag-\($0)"]] as [String: Any] }
        let snapshot: [String: Any] = ["ok": true, "result": [
            "selectedGraphId": "tag-actions", "graphName": "Tag actions",
            "selectedPage": ["uuid": "owner", "title": "Project"], "outlinerRows": [],
            "nodeProperties": ["ownerUuid": "owner", "canAdd": true, "classSchema": true,
                "properties": [], "schemaProperties": [["attr": "user.property/Notes", "title": "Notes"]],
                "availableProperties": [["attr": "user.property/Summary", "title": "Summary"]],
                "tagPicker": ["attr": "block/tags", "title": "Set tags", "many": true, "ref": true,
                    "raw": ["type": "set", "value": []], "filterValues": options]]]]
        try runtime.applyCoreResponse(String(decoding: JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func failure(_ message: String) -> NSError {
            NSError(domain: "TagPropertyActions", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw failure(message + ": " + (runtime.lastError ?? ""))
        }
        func press(_ identifier: String) throws {
            guard let id = find(identifier) else { throw failure("Missing action: " + identifier) }
            try backend.performPress(node: id)
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; runtime.stop() }
        try await wait("The tag page must expose its menu") { find("button.page.tag-properties") != nil }
        guard find("property.schema.owner.user.property/Notes") == nil else {
            throw failure("Tag schema properties must stay out of the reading content")
        }
        try press("button.page.tag-properties")
        try await wait("Tag properties must present a native sheet") {
            find("property.schema.owner.user.property/Notes") != nil && window.rootViewController?.presentedViewController != nil
        }
        try await Task.sleep(for: .milliseconds(400))
        try press("property.add.owner")
        try await wait("Add property must open inside Tag properties") {
            find("property.add.option.owner.user.property/Summary") != nil
        }
        try press("property.add.owner.cancel")
        try await Task.sleep(for: .milliseconds(400))
        try press("property.schema.remove.owner.user.property/Notes")
        try await wait("Removing a schema property must target the tag") {
            effects.requests.contains { $0["action"] as? String == "remove" && $0["blockUuid"] as? String == "owner" }
        }
        try press("sheet.tag-properties.done.owner")
        try await wait("Tag properties must dismiss") { window.rootViewController?.presentedViewController == nil }
        let opened = ProcessInfo.processInfo.systemUptime
        try press("button.page.tags")
        try await wait("The first tag page must mount") { find("view.edit.option.page.tags.owner.tag-0") != nil }
        let mountMs = (ProcessInfo.processInfo.systemUptime - opened) * 1000
        guard find("view.edit.option.page.tags.owner.tag-499") == nil else {
            throw failure("A large picker must not mount every candidate when opening")
        }
        try backend.performTextChange(node: find("view.edit.value.page.tags.owner")!, text: "PerfTag499")
        try await wait("Searching must include tags outside the mounted page") {
            find("view.edit.option.page.tags.owner.tag-499") != nil
        }
        guard runtime.lastError == nil else { throw failure(runtime.lastError!) }
        print("PASS: native Tag properties supports nested addition and removal; 500-tag picker first-page mount=\(mountMs) ms and searches its full catalog")
    }
}
