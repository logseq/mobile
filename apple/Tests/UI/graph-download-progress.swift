import Foundation
import SwiftUI
import UIKit
import LogseqCoreABI
@testable import LogseqModel
@testable import Logseq

@main struct CheckGraphDownloadProgress {
    @MainActor static func main() async throws {
        let coordinator = LGPlatformPresentationCoordinator()
        let store = LogseqStore(call: { _ in fatalError("Presentation must not wait for the core") })
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        let root = UIHostingController(rootView: Text("Graph download check").modifier(
            LGPlatformPresentationHost(coordinator: coordinator, store: store, stageAsset: { _ in })))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            GraphImportProgressRelay.report = nil
            LogseqCoreABI.logseq_set_graph_import_progress_callback(nil)
            window.isHidden = true
        }
        GraphImportProgressRelay.report = { id, phase, completed, total in
            coordinator.graphDownloadProgress = LogseqGraphDownloadProgress(
                graphId: id, graphName: "Test graph", phase: phase,
                completedItems: completed, totalItems: total)
        }
        LogseqCoreABI.logseq_set_graph_import_progress_callback(receiveGraphImportProgress)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let worker = Task {
            await LogseqCore.performUIAsync {
                LogseqCoreABI.logseq_graph_import_progress("test", "importing", 1024, 4096)
                _ = release.wait(timeout: .now() + 8)
                return ""
            }
        }
        for _ in 0..<100 {
            if root.presentedViewController != nil { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        precondition(root.presentedViewController != nil,
                     "Import progress must render while the core worker is still busy")
        precondition(coordinator.graphDownloadProgress?.completedItems == 1024)
        precondition(coordinator.graphDownloadProgress?.totalItems == 4096)
        release.signal()
        _ = await worker.value
        coordinator.graphDownloadProgress = nil
        for _ in 0..<100 {
            if root.presentedViewController == nil { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        precondition(root.presentedViewController == nil, "Finishing the import must close its sheet")
        print("PASS: native import progress counts records and renders while the core worker is busy")
    }
}
