import Foundation
import LogseqModel
import Testing
@testable import Logseq

@Suite struct ErrorFeedbackIntegrationTests {
    @Test @MainActor func reportAndRefreshKeepLastErrorOutsideTheSourceFilter() async throws {
        let log = LogseqRuntimeLog()
        let handler = LGPlatformEffectHandler(saveSettings: { _ in }, persistComposerDraft: { _ in },
            runtimeLog: log, copyText: { _ in }, signOut: {})
        let reported = await handler.execute(LGEffect(id: 1, kind: "report-error", text: "Hosted authentication failed"))
        #expect(reported.succeeded)
        #expect(reported.output == .discard)
        #expect(log.lastError?.message == "Hosted authentication failed")
        let refreshed = await handler.execute(LGEffect(id: 2, kind: "refresh-runtime-log", text: "core", value: 1))
        #expect(refreshed.succeeded)
        #expect(refreshed.output == .hostUpdate("runtime-log"))
        let snapshot = try #require(JSONSerialization.jsonObject(with: Data(refreshed.message.utf8)) as? [String: Any])
        #expect((snapshot["records"] as? [Any])?.isEmpty == true)
        let error = try #require(snapshot["lastError"] as? [String: Any])
        #expect(error["message"] as? String == "Hosted authentication failed")
        #expect(error["source"] as? String == "ui")
    }
}
