
import Foundation
import LogseqModel

import AuthenticationServices
import Security
#if os(iOS)
import UIKit
#endif

enum CognitoAuthProviderError: Error, LocalizedError {
    case invalidConfiguration
    case missingIDToken
    case missingRefreshToken
    case secureStorage(Int32)
    case tokenRequest(String)
    case webAuthenticationUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Cognito Hosted UI is not configured."
        case .missingIDToken:
            return "Cognito did not return an ID token."
        case .missingRefreshToken:
            return "Cognito did not return a refresh token."
        case .secureStorage(let status):
            return "Secure authentication storage failed (\(status))."
        case .tokenRequest(let reason):
            return "Cognito token request failed: \(reason)"
        case .webAuthenticationUnavailable:
            return "Could not open the secure sign-in page."
        }
    }
}

private struct CognitoTokenStore: Sendable {
    private let service = "com.logseq.logseq.cognito.tokens"
    private let account = "current-session"

    func load() throws -> CognitoStoredTokens? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CognitoAuthProviderError.secureStorage(status)
        }
        return try JSONDecoder().decode(CognitoStoredTokens.self, from: data)
    }

    func save(_ tokens: CognitoStoredTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        var query = baseQuery
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            query[kSecValueData] = data
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CognitoAuthProviderError.secureStorage(addStatus)
            }
        } else if status != errSecSuccess {
            throw CognitoAuthProviderError.secureStorage(status)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CognitoAuthProviderError.secureStorage(status)
        }
    }

    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
    }
}

@MainActor private final class CognitoWebAuthenticationSession:
    NSObject, ASWebAuthenticationPresentationContextProviding
{
    private var session: ASWebAuthenticationSession?

    func authenticate(at url: URL, callbackURLScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme
            ) { [weak self] callbackURL, error in
                self?.session = nil
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CognitoAuthProviderError.webAuthenticationUnavailable)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: CognitoAuthProviderError.webAuthenticationUnavailable)
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

@MainActor final class CognitoAuthProvider: LogseqCognitoProviding {
    private let configuration: CognitoOAuthConfiguration
    private let tokenStore = CognitoTokenStore()
    private let webAuthentication = CognitoWebAuthenticationSession()

    init(
        region: String,
        userPoolId: String,
        appClientId: String,
        oauthDomain: String,
        redirectURI: String,
        logoutURI: String,
        scopes: [String]
    ) {
        _ = region
        _ = userPoolId
        configuration = CognitoOAuthConfiguration(
            domain: oauthDomain,
            clientID: appClientId,
            redirectURI: redirectURI,
            logoutURI: logoutURI,
            scopes: scopes
        )
    }

    func apiToken() async throws -> String? {
        guard var tokens = try tokenStore.load() else { return nil }
        guard tokens.requiresRefresh(at: Date()) else { return tokens.idToken }
        guard !tokens.refreshToken.isEmpty else {
            try tokenStore.clear()
            return nil
        }
        do {
            let response = try await requestTokens(
                body: CognitoOAuthRequest.refreshTokenForm(
                    configuration: configuration,
                    refreshToken: tokens.refreshToken
                )
            )
            tokens = response.storedTokens(
                previousRefreshToken: tokens.refreshToken,
                now: Date()
            )
            try tokenStore.save(tokens)
            return tokens.idToken
        } catch {
            try? tokenStore.clear()
            throw error
        }
    }

    func signIn() async throws -> String {
        try validateConfiguration()
        guard let callbackScheme = URL(string: configuration.redirectURI)?.scheme else {
            throw CognitoAuthProviderError.invalidConfiguration
        }
        let state = try randomURLSafeString(byteCount: 24)
        let codeVerifier = try randomURLSafeString(byteCount: 64)
        let authorizationURL = try CognitoOAuthRequest.authorizationURL(
            configuration: configuration,
            state: state,
            codeChallenge: CognitoPKCE.codeChallenge(for: codeVerifier)
        )
        let callbackURL = try await webAuthentication.authenticate(
            at: authorizationURL,
            callbackURLScheme: callbackScheme
        )
        let code = try CognitoOAuthCallback.authorizationCode(
            from: callbackURL,
            expectedState: state
        )
        let response = try await requestTokens(
            body: CognitoOAuthRequest.authorizationCodeForm(
                configuration: configuration,
                code: code,
                codeVerifier: codeVerifier
            )
        )
        let tokens = response.storedTokens(previousRefreshToken: nil, now: Date())
        guard let idToken = tokens.idToken, !idToken.isEmpty else {
            throw CognitoAuthProviderError.missingIDToken
        }
        guard !tokens.refreshToken.isEmpty else {
            throw CognitoAuthProviderError.missingRefreshToken
        }
        try tokenStore.save(tokens)
        return idToken
    }

    func signOut() async throws {
        let tokens = try tokenStore.load()
        try tokenStore.clear()
        guard let refreshToken = tokens?.refreshToken, !refreshToken.isEmpty else { return }
        try? await revoke(refreshToken: refreshToken)
    }

    private func validateConfiguration() throws {
        guard
            !configuration.domain.isEmpty,
            !configuration.clientID.isEmpty,
            URL(string: configuration.redirectURI) != nil
        else {
            throw CognitoAuthProviderError.invalidConfiguration
        }
    }

    private func requestTokens(body: String) async throws -> CognitoOAuthTokenResponse {
        let url = URL(string: "https://\(configuration.domain)/oauth2/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let reason = (try? JSONDecoder().decode(CognitoOAuthFailureResponse.self, from: data).error)
                ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            throw CognitoAuthProviderError.tokenRequest(reason)
        }
        let tokens = try JSONDecoder().decode(CognitoOAuthTokenResponse.self, from: data)
        guard !tokens.idToken.isEmpty else {
            throw CognitoAuthProviderError.missingIDToken
        }
        return tokens
    }

    private func revoke(refreshToken: String) async throws {
        let body = CognitoOAuthRequest.formEncoded([
            "client_id": configuration.clientID,
            "token": refreshToken,
        ])
        let url = URL(string: "https://\(configuration.domain)/oauth2/revoke")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        _ = try await URLSession.shared.data(for: request)
    }

    private func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CognitoAuthProviderError.secureStorage(errSecAllocate)
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct CognitoOAuthFailureResponse: Decodable {
    let error: String
}
