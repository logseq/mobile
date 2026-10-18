import Foundation
import Testing
@testable import LogseqModel

private actor FakeCognitoProvider: LogseqCognitoProviding {
    private var token: String?
    private let signInToken: String
    private var signOutCount = 0

    init(token: String?, signInToken: String = "signed-in-access-token") {
        self.token = token
        self.signInToken = signInToken
    }

    func apiToken() async throws -> String? {
        token
    }

    func signIn() async throws -> String {
        token = signInToken
        return signInToken
    }

    func signOut() async throws {
        token = nil
        signOutCount += 1
    }

    func recordedSignOutCount() -> Int {
        signOutCount
    }
}

private struct FailingCognitoProvider: LogseqCognitoProviding {
    struct SessionError: Error, LocalizedError {
        var errorDescription: String? { "Could not restore the Cognito session." }
    }

    func apiToken() async throws -> String? {
        throw SessionError()
    }

    func signIn() async throws -> String {
        throw SessionError()
    }

    func signOut() async throws {
    }
}

@Suite struct AuthenticationTests {
    @Test @MainActor func restoresAndRefreshesAnExistingAccessToken() async throws {
        let provider = FakeCognitoProvider(token: "restored-access-token")
        let auth = LogseqAuthenticationStore(provider: provider)

        await auth.restore()

        #expect(auth.state == .signedIn)
        #expect(try await auth.apiToken() == "restored-access-token")
    }

    @Test @MainActor func signsInAndPublishesOnlyTheAccessToken() async throws {
        let provider = FakeCognitoProvider(token: nil)
        var published: [String] = []
        let auth = LogseqAuthenticationStore(provider: provider) { token in
            if let token {
                published.append(token)
            }
        }

        await auth.signIn()

        #expect(auth.state == .signedIn)
        #expect(published == ["signed-in-access-token"])
        #expect(auth.errorMessage == nil)
    }

    @Test @MainActor func hostedSignInFailureLeavesAuthenticationSignedOut() async {
        var published: [String?] = []
        let auth = LogseqAuthenticationStore(provider: FailingCognitoProvider()) { token in
            published.append(token)
        }

        await auth.signIn()

        #expect(auth.state == .signedOut)
        #expect(auth.errorMessage == "Could not restore the Cognito session.")
        #expect(published == [nil])
    }

    @Test @MainActor func signsOutAndClearsPublishedAuthorization() async throws {
        let provider = FakeCognitoProvider(token: "access-token")
        var published: [String?] = []
        let auth = LogseqAuthenticationStore(provider: provider) { token in
            published.append(token)
        }
        await auth.restore()

        await auth.signOut()

        #expect(auth.state == .signedOut)
        #expect(published == ["access-token", nil])
        #expect(await provider.recordedSignOutCount() == 1)
    }

    @Test @MainActor func accessTokenFailureUpdatesObservableAuthenticationState() async {
        var published: [String?] = []
        let auth = LogseqAuthenticationStore(provider: FailingCognitoProvider()) { token in
            published.append(token)
        }

        do {
            _ = try await auth.apiToken()
            #expect(1 == 0, "Expected access token restoration to fail")
        } catch {
            #expect(auth.state == .signedOut)
            #expect(auth.errorMessage?.isEmpty == false)
            #expect(published == [nil])
        }
    }

    @Test @MainActor func missingAccessTokenLeavesExpectedSignedOutStateWithoutAnError() async {
        var published: [String?] = []
        let auth = LogseqAuthenticationStore(provider: FakeCognitoProvider(token: nil)) { token in
            published.append(token)
        }

        do {
            _ = try await auth.apiToken()
            #expect(1 == 0, "Expected a missing access token to throw")
        } catch {
            #expect(auth.state == .signedOut)
            #expect(auth.errorMessage == nil)
            #expect(published == [nil])
        }
    }
}
