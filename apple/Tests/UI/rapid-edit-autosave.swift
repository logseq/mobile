import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class RapidEditingEffects: LGEffectExecuting {
    var draft = "Before"
    var saved = "Before"
    var serverTitle = "Before"
    var depth = 0
    var moves = 0
    var saves = 0

    func response(patch: Bool = false) -> String {
        let result: [String: Any] = [
            "graphName": "Autosave regression", "selectedGraphId": "autosave",
            "syncConnected": true, "hasPendingSemanticOperations": saved != serverTitle,
            "isOutlinerPatch": patch,
            "outlinerRows": [
                ["depth": 0, "hasChildren": depth == 1,
                 "block": ["uuid": "previous", "title": "Parent", "pageId": "page"]],
                ["depth": depth, "block": ["uuid": "editing", "title": saved, "pageId": "page"]]
            ],
            "outlinerState": ["editing": ["uuid": "editing", "title": draft,
                "caretUTF16Offset": draft.utf16.count], "selectedBlockIds": []]
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
    }

    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        switch effect.kind {
        case "change-outliner-text": draft = effect.text
        case "outliner-toolbar":
            if effect.text == "indent" { depth = 1 }
            if effect.text == "outdent" { depth = 0 }
            if ["indent", "outdent", "moveUp", "moveDown"].contains(effect.text) { moves += 1 }
        case "save-outliner-editing": saved = draft; saves += 1
        case "sync-pending":
            serverTitle = saved
            return LGEffectResolution(succeeded: true, message: response())
        default:
            return LGEffectResolution(succeeded: true, message: "", output: .discard)
        }
        return LGEffectResolution(succeeded: true, message: response(patch: true))
    }
}

@main struct RapidEditAutosaveCheck {
    @MainActor static func main() async throws {
        let effects = RapidEditingEffects()
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
        try runtime.applyCoreResponse(effects.response())
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        try await Task.sleep(for: .milliseconds(600))
        let backend = runtime.renderer.backend
        func ids(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(ids)
        }
        func find(_ identifier: String) throws -> Int {
            guard let id = backend.rootIDs.flatMap(ids).first(where: {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
                || backend.extensionModel(id: $0)?.identifier == identifier
            }) else { throw failure("Missing native control: \(identifier)") }
            return id
        }
        for index in 1...60 {
            let title = "Draft \(index)"
            try backend.performExtensionEvent(node: find("outliner-editor"), name: "text-change",
                values: ["title": .string(title), "caret-utf16-offset": .int(title.utf16.count)])
            try await Task.sleep(for: .milliseconds(25))
            let action = ["indent", "outdent", "moveUp", "moveDown"][(index - 1) % 4]
            try backend.performPress(node: find("button.outliner.editor.\(action)"))
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(1200))
        guard effects.moves == 60, effects.saved == "Draft 60", effects.serverTitle == "Draft 60" else {
            throw failure("Rapid editing stranded a draft: moves=\(effects.moves), saves=\(effects.saves), saved=\(effects.saved), server=\(effects.serverTitle)")
        }
        // Returning to the saved text produces a successful save without a transaction.
        for title in ["Draft 60x", "Draft 60"] {
            try backend.performExtensionEvent(node: find("outliner-editor"), name: "text-change",
                values: ["title": .string(title), "caret-utf16-offset": .int(title.utf16.count)])
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(1600))
        let sync = try find("sync.connected")
        guard backend.model(id: sync)?.property(.accessibilityLabel)?.stringValue == "Synced" else {
            throw failure("An acknowledged no-op save left the native sync status stuck")
        }
        try backend.performPress(node: sync)
        try await Task.sleep(for: .milliseconds(350))
        guard backend.model(id: try find("sync.pending"))?.property(.text)?.stringValue == "Saved" else {
            throw failure("The native details must confirm that local changes are saved")
        }
        window.rootViewController?.presentedViewController?.sheetPresentationController?.selectedDetentIdentifier = .large
        try await Task.sleep(for: .milliseconds(350))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("rapid-edit-synced.png"))
        print("PASS: 60 native text changes with indent/outdent and move up/down save the final draft, synchronize it, and settle after a no-op save")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "RapidEditAutosave", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
