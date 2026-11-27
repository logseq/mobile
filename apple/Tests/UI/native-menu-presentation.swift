import SwiftUI
@testable import LUIAppleBackend
@testable import Logseq

@main struct NativeMenuPresentationCheck: App {
    private let fixture = NativeMenuPresentationFixture()

    var body: some Scene {
        WindowGroup {
            LGRendererRoot(renderer: fixture.runtime.renderer)
                .modifier(LGPlatformPresentationHost(
                    coordinator: fixture.coordinator, confirmOutlinerDelete: {}, stageAsset: fixture.stageAsset
                ))
        }
    }
}

@MainActor private final class NativeMenuPresentationFixture {
    let coordinator = LGPlatformPresentationCoordinator()
    var runtime: LGRuntime!

    private func record(_ value: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("presentation.txt")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try (previous + value + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch { fatalError("Cannot record menu presentation events: \(error)") }
    }

    func stageAsset(_ payload: String) throws {
        record("STAGED " + payload)
        try runtime.applyHostUpdate(kind: "composer-asset", payload: payload)
    }

    init() {
        do {
            record("READY")
            let snapshot = #"{"ok":true,"result":{"revision":1,"graphName":"Work","selectedGraphId":"work","graphs":[{"id":"work","name":"Work","isReady":true,"isEncrypted":false},{"id":"other","name":"Other","isReady":true,"isEncrypted":false}],"blocks":[],"outlinerRows":[],"outlinerState":{"selectedBlockIds":[]}}}"#
            let platform = LGPlatformEffectHandler(saveSettings: { _ in }, runtimeLog: .shared, copyText: { _ in }, signOut: {}, presentAttachment: { [self] kind in
                record("REQUEST " + kind)
                return coordinator.presentAttachment(kind)
            })
            let executor = LGCoreEffectExecutor(callCore: { _ in snapshot }, platformEffect: { await platform.execute($0) })
            runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: executor)
            try runtime.applyCoreResponse(snapshot)
            try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
            try runtime.applyHostUpdate(kind: "graph-loading", payload: "false")
            let receive = runtime.renderer.onEvent
            runtime.renderer.onEvent = { [self] event in
                let identifier = runtime.renderer.backend.model(id: event.nodeID)?.property(.accessibilityIdentifier)?.stringValue ?? ""
                let detail = event.kind == .extension
                    ? "\(event.extensionIdentifier ?? "") \(event.extensionName ?? "")" : identifier
                record("EVENT \(event.kind) " + detail)
                receive?(event)
            }
        } catch { fatalError("Native menu presentation fixture failed: \(error)") }
    }
}
