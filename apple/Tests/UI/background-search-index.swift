import Foundation
@testable import Logseq

@main struct BackgroundSearchIndexCheck {
    @MainActor static func main() async throws {
        let response = #"{"apiVersion":1,"ok":true,"result":{"searchIndexReady":true}}"#
        let executor = LGCoreEffectExecutor(callCore: { _ in
            response
        })
        let result = await executor.execute(LGEffect(id: 1, kind: "maintain-search-index", text: "graph"))
        guard result.succeeded, case .discard = result.output else {
            throw NSError(domain: "BackgroundSearchIndex", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Index maintenance must not replace the active UI snapshot"])
        }
        guard result.message == response else {
            throw NSError(domain: "BackgroundSearchIndex", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Completion must reach the shared search reducer"])
        }
        print("PASS: index maintenance completes without replacing the active UI snapshot")
    }
}
