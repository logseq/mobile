import Foundation
import LogseqModel
import Testing
@testable import Logseq

private enum RefreshReply {
    case http(Int, String)
    case network(URLError.Code)
}

private final class RefreshReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: [RefreshReply]] = [:]
    func register(_ host: String, _ values: [RefreshReply]) {
        lock.withLock { replies[host] = values }
    }

    func take(_ host: String) -> RefreshReply {
        lock.withLock {
            guard var values = replies[host], !values.isEmpty else {
                return .http(500, "Unexpected token request")
            }
            let next = values.removeFirst()
            replies[host] = values
            return next
        }
    }

    func remove(_ host: String) {
        _ = lock.withLock { replies.removeValue(forKey: host) }
    }
}

private final class RefreshURLProtocol: URLProtocol, @unchecked Sendable {
    static let replies = RefreshReplies()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".auth-test.invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-amz-json-1.1")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Target")?.hasPrefix("AWSCognitoIdentityProviderService.") == true)
        #expect(url.path == "/")
        switch Self.replies.take(url.host!) {
        case .network(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@Suite struct CognitoRefreshTests {
    private static let success = RefreshReply.http(200,
        #"{"AuthenticationResult":{"IdToken":"renewed-id-token","RefreshToken":"rotated-refresh-token","ExpiresIn":3600}}"#)

    @MainActor private func withProvider(
        replies: [RefreshReply],
        expiresAt: Date = .distantPast,
        refreshToken: String = "stored-refresh-token",
        check: (CognitoAuthProvider, CognitoTokenStore) async throws -> Void
    ) async throws {
        let host = UUID().uuidString.lowercased() + ".auth-test.invalid"
        let store = CognitoTokenStore(service: "com.logseq.auth-tests." + host)
        try store.save(CognitoStoredTokens(idToken: "expired-id-token", refreshToken: refreshToken,
            expiresAt: expiresAt))
        RefreshURLProtocol.replies.register(host, replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            RefreshURLProtocol.replies.remove(host)
            try? store.clear()
        }
        let provider = CognitoAuthProvider(region: "test", userPoolId: "test", appClientId: "test",
            tokenStore: store, urlSession: session, endpoint: URL(string: "https://\(host)/")!)
        try await check(provider, store)
    }

    @Test @MainActor func temporaryFailuresRetainCredentialsAndRetryWithoutSigningIn() async throws {
        let failures: [RefreshReply] = [
            .network(.notConnectedToInternet), .network(.timedOut), .network(.cancelled),
            .http(500, #"{"error":"server_error"}"#),
            .http(429, #"{"error":"temporarily_unavailable"}"#),
            .http(401, #"{"error":"unauthorized"}"#),
            .http(400, #"{"error":"invalid_client"}"#),
            .http(200, "malformed JSON"),
            .http(200, #"{"AuthenticationResult":{"IdToken":"","ExpiresIn":3600}}"#),
        ]
        for failure in failures {
            try await withProvider(replies: [failure, Self.success]) { (provider, store) async throws in
                let auth = LogseqAuthenticationStore(provider: provider)
                await auth.restore()
                #expect(auth.state == .signedIn)
                #expect(auth.errorMessage != nil)
                #expect(try store.load()?.refreshToken == "stored-refresh-token")
                #expect(try store.load()?.idToken == "expired-id-token")
                #expect(try await auth.apiToken() == "renewed-id-token")
                #expect(auth.state == .signedIn)
                #expect(auth.errorMessage == nil)
                #expect(try store.load()?.refreshToken == "rotated-refresh-token")
            }
        }
    }

    @Test @MainActor func invalidRefreshTokensClearCredentialsAndRequireSignIn() async throws {
        for code in ["NotAuthorizedException", "RefreshTokenReuseException"] {
            try await withProvider(replies: [.http(400, "{\"__type\":\"\(code)\"}")]) { (provider, store) async throws in
                let auth = LogseqAuthenticationStore(provider: provider)
                await auth.restore()
                #expect(auth.state == .signedOut)
                #expect(try store.load() == nil)
            }
        }
    }

    @Test @MainActor func validTokenDoesNotRefresh() async throws {
        try await withProvider(replies: [], expiresAt: .distantFuture) { (provider, store) async throws in
            #expect(try await provider.apiToken() == "expired-id-token")
            #expect(try store.load()?.refreshToken == "stored-refresh-token")
        }
    }

    @Test @MainActor func missingRefreshTokenRequiresSignIn() async throws {
        try await withProvider(replies: [], refreshToken: "") { (provider, store) async throws in
            #expect(try await provider.apiToken() == nil)
            #expect(try store.load() == nil)
        }
    }

    @Test @MainActor func directAuthenticationStoresTokensAndReturnsOnlyCompletion() async throws {
        try await withProvider(replies: [Self.success]) { (provider, store) async throws in
            let reply = try await provider.authenticate(#"{"operation":"InitiateAuth","body":{"AuthFlow":"USER_PASSWORD_AUTH","AuthParameters":{"USERNAME":"test@example.com","PASSWORD":"fixture-password"}}}"#)
            let result = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as! [String: Any]
            #expect(result["signedIn"] as? Bool == true)
            #expect(!reply.contains("renewed-id-token"))
            #expect(!reply.contains("rotated-refresh-token"))
            #expect(try store.load()?.idToken == "renewed-id-token")
        }
    }

    @Test @MainActor func challengesAndServiceErrorsNeverReplaceTokens() async throws {
        for reply in [
            RefreshReply.http(200, #"{"ChallengeName":"SMS_MFA","Session":"challenge-session","ChallengeParameters":{}}"#),
            RefreshReply.http(400, #"{"__type":"NotAuthorizedException","message":"raw service details"}"#),
        ] {
            try await withProvider(replies: [reply]) { (provider, store) async throws in
                let response = try await provider.authenticate(#"{"operation":"InitiateAuth","body":{}}"#)
                #expect(!response.contains("signedIn"))
                #expect(!response.contains("raw service details"))
                #expect(try store.load()?.idToken == "expired-id-token")
            }
        }
    }

    @Test @MainActor func incompleteAuthenticationCannotOverwriteStoredSession() async throws {
        try await withProvider(replies: [.http(200, #"{"AuthenticationResult":{"IdToken":"incomplete","ExpiresIn":3600}}"#)]) { (provider, store) async throws in
            do {
                _ = try await provider.authenticate(#"{"operation":"InitiateAuth","body":{}}"#)
                Issue.record("An initial login requires a refresh token")
            } catch {
                #expect(try store.load()?.idToken == "expired-id-token")
            }
        }
    }
}
