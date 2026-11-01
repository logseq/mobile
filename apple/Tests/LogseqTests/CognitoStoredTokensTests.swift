import Foundation
import Testing
@testable import Logseq

@Suite struct CognitoStoredTokensTests {
    @Test func tokenExpiryRefreshesEarlyAndPreservesIDToken() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let current = CognitoStoredTokens(
            idToken: "id",
            refreshToken: "refresh",
            expiresAt: now.addingTimeInterval(120)
        )
        #expect(!current.requiresRefresh(at: now))
        #expect(current.requiresRefresh(at: now.addingTimeInterval(61)))

        let persisted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as! [String: Any]
        #expect(persisted["idToken"] as? String == "id")
        var previousSession = persisted
        previousSession.removeValue(forKey: "idToken")
        previousSession["accessToken"] = "old-access"
        let restored = try JSONDecoder().decode(CognitoStoredTokens.self, from: JSONSerialization.data(withJSONObject: previousSession))
        #expect(restored.requiresRefresh(at: now))
    }
}
