import Foundation
@testable import Logseq
import LogseqModel

@main struct SyncSubscriptionStabilityCheck {
    @MainActor static func main() async throws {
        let coordinator = GraphSyncCoordinator()
        var starts = 0
        var pendingRequests = 0
        await coordinator.startForeground(graphID: "work") { _ in
            starts += 1
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
        }
        let handler = LGPlatformEffectHandler(
            saveSettings: { _ in }, runtimeLog: LogseqRuntimeLog(capacity: 1),
            copyText: { _ in }, signOut: {},
            syncPending: { pendingRequests += 1 },
            syncNow: { Task { await coordinator.kickForeground() } }
        )
        let executor = LGCoreEffectExecutor(platformEffect: { await handler.execute($0) })
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: executor)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 3)
        for connected in [false, true, true, false, true, true] {
            let snapshot = """
            {"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],
            "graphName":"Work","selectedGraphId":"work","outlinerRows":[],
            "outlinerState":{"selectedBlockIds":[]},"syncConnected":\(connected),
            "hasPendingSemanticOperations":true}}
            """
            try runtime.applyCoreResponse(snapshot)
            await runtime.drainEffectsForTesting()
            try await Task.sleep(for: .milliseconds(30))
        }
        let automaticStarts = starts
        print("Automatic sync: subscriptions=\(automaticStarts), pending requests=\(pendingRequests)")
        guard automaticStarts == 1, pendingRequests > 0 else {
            await coordinator.stopForeground()
            throw failure("Automatic pending projections restarted the foreground subscription")
        }
        _ = await handler.execute(LGEffect(id: 99, kind: "sync-now", text: ""))
        try await Task.sleep(for: .milliseconds(30))
        await coordinator.stopForeground()
        guard starts == 2 else { throw failure("Explicit Sync now must still recover the subscription") }
        print("PASS: automatic pending sync preserves the subscription; manual Sync now can restart it")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SyncSubscriptionStability", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
