import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class RejectionEffects: LGEffectExecuting {
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct SyncRejectionsCheck {
    @MainActor static func main() async throws {
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: RejectionEffects())
        func response(_ error: String?, patch: Bool) throws -> String {
            let result: [String: Any] = ["selectedGraphId": "sync-errors", "graphName": "Sync rejection regression",
                "syncConnected": true, "hasPendingSemanticOperations": true, "pendingSyncRequest": NSNull(),
                "isPendingSyncPatch": patch, "pendingSyncError": error as Any? ?? NSNull(),
                "blocks": [], "outlinerRows": []]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        try runtime.applyCoreResponse(response(nil, patch: false))
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        let backend = runtime.renderer.backend
        func ids(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(ids)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(ids).first { backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier }
        }
        try await Task.sleep(for: .milliseconds(600))
        guard let sync = find("sync.connected") else { throw failure("Missing native sync details control") }
        try backend.performPress(node: sync)
        try await Task.sleep(for: .milliseconds(300))
        for error in [
            "Create page (page-1): Sync server returned HTTP 403: permission denied",
            "Save block (block-1): Sync server returned HTTP 409: graph is not ready",
            "Create page (page-2): Sync server rejected the change: db transact failed — missing Page type; 中文 😀"
        ] {
            try runtime.applyCoreResponse(response(error, patch: true))
            try await Task.sleep(for: .milliseconds(350))
            guard let node = find("sync.error"), backend.model(id: node)?.property(.text)?.stringValue == error else {
                throw failure("A server rejection was lost or hidden by unchanged pending flags: \(error)")
            }
            try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
            try await Task.sleep(for: .milliseconds(50))
            guard backend.model(id: node)?.property(.text)?.stringValue == error else {
                throw failure("An unrelated UI update erased the rejection")
            }
        }
        window.rootViewController?.presentedViewController?.sheetPresentationController?.selectedDetentIdentifier = .large
        try await Task.sleep(for: .milliseconds(350))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent("sync-rejection-detail.png"))
        try runtime.applyCoreResponse(response(nil, patch: true))
        try await Task.sleep(for: .milliseconds(350))
        guard find("sync.error") == nil else { throw failure("A resolved failure remains visible") }
        print("PASS: native sync details show HTTP and transaction rejections, retain Unicode and changing reasons, and clear resolved failures")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SyncRejections", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
