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
        #"{"id_token":"renewed-id-token","refresh_token":"rotated-refresh-token","expires_in":3600}"#)

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
            oauthDomain: host, redirectURI: "logseq://auth/callback", logoutURI: "logseq://auth/logout",
            scopes: ["openid"], tokenStore: store, urlSession: session)
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
            .http(200, #"{"id_token":"","expires_in":3600}"#),
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
        for code in ["invalid_grant", "invalid_token"] {
            try await withProvider(replies: [.http(400, "{\"error\":\"\(code)\"}")]) { (provider, store) async throws in
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
}
