import Foundation
import Testing
@testable import Logseq

@Suite struct CognitoOAuthTests {
    private let configuration = CognitoOAuthConfiguration(
        domain: "auth.example.com",
        clientID: "mobile-client",
        redirectURI: "logseq://auth/callback",
        logoutURI: "logseq://auth/logout",
        scopes: ["openid", "email", "profile"]
    )

    @Test func authorizationUsesCodeFlowPKCEAndState() throws {
        let url = try CognitoOAuthRequest.authorizationURL(
            configuration: configuration,
            state: "state-value",
            codeChallenge: "challenge-value"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })

        #expect(components.scheme == "https")
        #expect(components.host == "auth.example.com")
        #expect(components.path == "/oauth2/authorize")
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == "mobile-client")
        #expect(query["redirect_uri"] == "logseq://auth/callback")
        #expect(query["scope"] == "openid email profile")
        #expect(query["state"] == "state-value")
        #expect(query["code_challenge"] == "challenge-value")
        #expect(query["code_challenge_method"] == "S256")
    }

    @Test func pkceMatchesTheRFC7636S256Vector() {
        #expect(CognitoPKCE.codeChallenge(
            for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        ) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func callbackRequiresMatchingStateAndAuthorizationCode() throws {
        let callback = try #require(URL(
            string: "logseq://auth/callback?code=authorization-code&state=expected"
        ))
        #expect(try CognitoOAuthCallback.authorizationCode(
            from: callback,
            expectedState: "expected"
        ) == "authorization-code")

        #expect(throws: CognitoOAuthError.invalidState) {
            try CognitoOAuthCallback.authorizationCode(from: callback, expectedState: "other")
        }
        #expect(throws: CognitoOAuthError.missingAuthorizationCode) {
            try CognitoOAuthCallback.authorizationCode(
                from: URL(string: "logseq://auth/callback?state=expected")!,
                expectedState: "expected"
            )
        }
        #expect(throws: CognitoOAuthError.authorizationFailed("access_denied")) {
            try CognitoOAuthCallback.authorizationCode(
                from: URL(string: "logseq://auth/callback?error=access_denied&state=expected")!,
                expectedState: "expected"
            )
        }
    }

    @Test func tokenFormsContainOnlyPublicClientParameters() throws {
        let authorization = CognitoOAuthRequest.authorizationCodeForm(
            configuration: configuration,
            code: "authorization-code",
            codeVerifier: "verifier"
        )
        let refresh = CognitoOAuthRequest.refreshTokenForm(
            configuration: configuration,
            refreshToken: "refresh-token"
        )

        #expect(formValues(authorization) == [
            "client_id": "mobile-client",
            "code": "authorization-code",
            "code_verifier": "verifier",
            "grant_type": "authorization_code",
            "redirect_uri": "logseq://auth/callback",
        ])
        #expect(formValues(refresh) == [
            "client_id": "mobile-client",
            "grant_type": "refresh_token",
            "refresh_token": "refresh-token",
        ])
        #expect(!authorization.contains("client_secret"))
        #expect(!refresh.contains("client_secret"))
    }

    @Test func tokenExpiryRefreshesEarlyAndPreservesIDToken() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let current = CognitoStoredTokens(
            idToken: "id",
            refreshToken: "refresh",
            expiresAt: now.addingTimeInterval(120)
        )
        #expect(!current.requiresRefresh(at: now))
        #expect(current.requiresRefresh(at: now.addingTimeInterval(61)))

        let response = try JSONDecoder().decode(CognitoOAuthTokenResponse.self, from: Data("""
        {"access_token":"new-access","id_token":"new-id","expires_in":3600}
        """.utf8))
        let refreshed = response.storedTokens(
            previousRefreshToken: current.refreshToken,
            now: now
        )
        #expect(refreshed.refreshToken == "refresh")
        #expect(refreshed.expiresAt == now.addingTimeInterval(3_600))
        let persisted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(refreshed)) as! [String: Any]
        #expect(persisted["idToken"] as? String == "new-id")
        var previousSession = persisted
        previousSession.removeValue(forKey: "idToken")
        previousSession["accessToken"] = "old-access"
        let restored = try JSONDecoder().decode(CognitoStoredTokens.self, from: JSONSerialization.data(withJSONObject: previousSession))
        #expect(restored.requiresRefresh(at: now))
    }

    private func formValues(_ body: String) -> [String: String] {
        var components = URLComponents()
        components.query = body
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
    }
}
