import SwiftUI
import UIKit
import Vision
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
        let forwardEvent = runtime.renderer.onEvent
        var delayedViewport: LGRendererEvent?
        var waitingForViewport = true
        runtime.renderer.onEvent = { event in
            if waitingForViewport, event.extensionIdentifier == "native-navigation-stack",
               event.extensionName == "viewport-changed" {
                delayedViewport = event
            } else {
                forwardEvent?(event)
            }
        }
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
        let startupGraphID = try node("button.graph-switch")
        guard let delayedViewport, frames[startupGraphID] == nil else {
            throw failure("The graph switch must wait until the native viewport has been measured")
        }
        waitingForViewport = false
        forwardEvent?(delayedViewport)
        try await Task.sleep(for: .milliseconds(500))
        guard frames[startupGraphID] != nil else {
            throw failure("The graph switch must appear as soon as the measured viewport is applied")
        }
        for name in ["My notes", "Short", "Query Demo 2026-10-22", "Abhilesh_Knowledge_Graph", String(repeating: "Long graph name ", count: 8), "Short again"] {
            try runtime.applyCoreResponse(snapshot(name))
            try await Task.sleep(for: .milliseconds(800))
            let graphID = try node("button.graph-switch")
            let sidebarID = try node("button.sidebar")
            guard let graph = frames[graphID], let sidebar = frames[sidebarID],
                  graph.minX >= sidebar.maxX - 1,
                  graph.maxX < window.bounds.width - 44,
                  abs(graph.midY - sidebar.midY) < 3 else {
                throw failure("The graph switch must fit between the header controls for \(name): graph=\(String(describing: frames[graphID])) sidebar=\(String(describing: frames[sidebarID]))")
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let rendered = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let header = graph.insetBy(dx: -2, dy: -2).integral
            let crop = rendered.cgImage!.cropping(to: header)!
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: crop).perform([request])
            let prefix = String(name.prefix(4)).lowercased()
            guard request.results?.contains(where: {
                $0.topCandidates(1).first?.string.lowercased().hasPrefix(prefix) == true
            }) == true else {
                throw failure("The visible graph name must retain its leading characters: " + name)
            }
        }
        print("PASS: the graph switch waits for the measured viewport and keeps long names readable")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SidebarLongGraphName", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
