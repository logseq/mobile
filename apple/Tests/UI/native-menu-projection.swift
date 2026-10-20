import Foundation
@testable import LUIAppleBackend

@main struct NativeMenuProjectionCheck {
    @MainActor static func main() throws {
        let native = LGCoreNativeCaller()
        let renderer = LGRenderer()
        renderer.backend.coalescesCommits = false
        defer { _ = native.dispose() }
        try renderer.apply(patchJSON: native.initialize(platformCode: 2, hostCode: 2, authenticationCode: 3))
        try renderer.apply(patchJSON: native.applySnapshot(#"{"ok":true,"result":{"graphName":"Work","selectedGraphId":"work","graphs":[{"id":"work","name":"Work","isReady":true,"isEncrypted":false},{"id":"preparing","name":"Preparing","isReady":false,"isEncrypted":false}],"blocks":[],"outlinerRows":[],"outlinerState":{"selectedBlockIds":[]}}}"#))
        let loading = native.applyHostUpdate(kind: "graph-loading", payload: "false")
        if !loading.isEmpty { try renderer.apply(patchJSON: loading) }
        func find(_ identifier: String, under root: Int? = nil) -> LUINodeModel? {
            func visit(_ id: Int) -> LUINodeModel? {
                guard let model = renderer.backend.model(id: id) else {
                    return renderer.backend.extensionModel(id: id)?.children.lazy.compactMap(visit).first
                }
                if model.property(.accessibilityIdentifier)?.stringValue == identifier { return model }
                return model.children.lazy.compactMap(visit).first
            }
            return (root ?? renderer.rootID).flatMap(visit)
        }
        func press(_ identifier: String) throws {
            guard let node = find(identifier) else { preconditionFailure("Missing \(identifier)") }
            let patch = native.press(node: node.id)
            if !patch.isEmpty { try renderer.apply(patchJSON: patch) }
        }
        let graph = find("button.graph-switch")!
        let graphMenu = find("menu.graph-switch", under: graph.id)!
        precondition(graphMenu.kind == .contextMenu)
        precondition(find("menu.graph.work", under: graphMenu.id)?.isSelected == true)
        precondition(find("menu.graph.preparing", under: graphMenu.id)?.isEnabled == false)
        try press("button.composer.expand")
        for identifier in ["button.attachment", "button.task-status"] {
            let trigger = find(identifier)!
            precondition(trigger.children.contains { renderer.backend.model(id: $0)?.kind == .contextMenu })
        }
        try press("button.task-status.option.todo")
        precondition(find("button.task-status.option.todo")?.isSelected == true)
        try press("button.task-status.clear")
        precondition(find("button.task-status.option.todo")?.isSelected == false)
        for service in ["files", "camera", "photos", "audio"] {
            precondition(find("button.attachment." + service)?.kind == .menuItem)
        }
        try press("button.attachment.files")
        var attachments = 0
        while true {
            let effect = native.takeEffect()
            if effect.isEmpty || effect.contains("waitMs") { break }
            let envelope = try JSONSerialization.jsonObject(with: Data(effect.utf8)) as! [String: Any]
            let value = envelope["effect"] as! [String: Any]
            if value["kind"] as? String == "present-attachment" {
                precondition(value["text"] as? String == "files")
                attachments += 1
            }
        }
        precondition(attachments == 1)
        print("PASS: real core menus validate and preserve selection, disabled graphs, clear status, and attachment actions")
    }
}
