import Foundation
import LogseqModel
import Security
@testable import Logseq

@main struct SessionReinstall {
    enum Failure: Error { case sessionWasLost }

    @MainActor static func main() async throws {
        let phase = Int(ProcessInfo.processInfo.environment["LOGSEQ_SESSION_REINSTALL_PHASE"] ?? "0") ?? 0
        print("SESSION_REINSTALL_PHASE=\(phase)")
        let store = CognitoTokenStore(service: "com.logseq.test.session-reinstall")
        if phase == 0 {
            try? store.clear()
            do {
                try store.save(CognitoStoredTokens(idToken: "legacy-fixture", refreshToken: "fixture-refresh", expiresAt: .distantFuture))
                print("KEYCHAIN_LEGACY_WRITE=succeeded")
            } catch { print("KEYCHAIN_LEGACY_WRITE=\(error)") }
        } else if phase == 1 {
            print("KEYCHAIN_LEGACY_VISIBLE=\((try? store.load()) != nil)")
            try store.save(CognitoStoredTokens(idToken: "reinstall-fixture", refreshToken: "fixture-refresh", expiresAt: .distantFuture))
        } else if phase == 2 {
            let provider = CognitoAuthProvider(region: "test", userPoolId: "test", appClientId: "test",
                oauthDomain: "auth-test.invalid", redirectURI: "logseq://auth/callback",
                logoutURI: "logseq://auth/logout", scopes: ["openid"], tokenStore: store)
            let auth = LogseqAuthenticationStore(provider: provider)
            await auth.restore()
            guard auth.state == .signedIn, try await auth.apiToken() == "reinstall-fixture" else {
                throw Failure.sessionWasLost
            }
            print("KEYCHAIN_STABLE_REINSTALL=signedIn")
            try store.clear()
        } else {
            try? store.clear()
            return
        }
    }
}
