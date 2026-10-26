import SwiftUI
import UIKit
@testable import Logseq
@testable import LUIAppleBackend

@main struct SidebarLongGraphNameCheck {
    @MainActor static func main() async throws {
        func snapshot(_ name: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": [
                "selectedGraphId": name, "graphName": name,
                "graphs": [["id": name, "name": name, "isReady": true, "isEncrypted": false]],
                "blocks": [], "outlinerRows": [], "outlinerState": ["selectedBlockIds": []]
            ]]), as: UTF8.self)
        }
        let first = try snapshot("Short")
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: LGCoreEffectExecutor(callCore: { _ in first }))
        try runtime.applyCoreResponse(first)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let backend = runtime.renderer.backend
        var frames: [Int: CGRect] = [:]
        backend.frameReportingEnabled = true
        backend.onFramesReport = { frames = $0 }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { runtime.stop(); window.isHidden = true; window.rootViewController = nil }
        func nodes(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(nodes)
        }
        func node(_ identifier: String) throws -> Int {
            guard let id = backend.rootIDs.flatMap(nodes).first(where: {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }) else { throw failure("Missing " + identifier) }
            return id
        }
        try await Task.sleep(for: .milliseconds(600))
        try backend.performPress(node: node("button.sidebar"))
        for name in ["Short", "Abhilesh_Knowledge_Graph", String(repeating: "Long graph name ", count: 8), "Short again"] {
            try runtime.applyCoreResponse(snapshot(name))
            try await Task.sleep(for: .milliseconds(800))
            let settingsID = try node("button.sidebar.settings")
            let graphID = try node("button.graph-switch")
            for _ in 0..<100 where frames[settingsID] == nil || frames[graphID] == nil {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let settings = frames[settingsID], let graph = frames[graphID],
                  settings.width >= 40, settings.height >= 40,
                  window.bounds.contains(settings), window.bounds.contains(graph),
                  settings.minX >= graph.maxX - 1 else {
                throw failure("Global settings must remain visible and unobscured for graph \(name): settings=\(String(describing: frames[settingsID])) graph=\(String(describing: frames[graphID]))")
            }
        }
        try backend.performPress(node: node("button.sidebar.settings"))
        try await Task.sleep(for: .milliseconds(300))
        guard backend.rootIDs.flatMap(nodes).contains(where: {
            backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == "sheet.settings"
        }) else { throw failure("Global settings must still open after switching graphs") }
        print("PASS: long graph names and graph switches preserve the visible global settings button")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SidebarLongGraphName", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
