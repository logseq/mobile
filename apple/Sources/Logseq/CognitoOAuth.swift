
import Foundation

import CryptoKit

struct CognitoOAuthConfiguration: Sendable {
    let domain: String
    let clientID: String
    let redirectURI: String
    let logoutURI: String
    let scopes: [String]
}

enum CognitoOAuthError: Error, Equatable, LocalizedError {
    case invalidState
    case missingAuthorizationCode
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidState:
            return "The sign-in response could not be verified."
        case .missingAuthorizationCode:
            return "Cognito did not return an authorization code."
        case .authorizationFailed(let reason):
            return "Sign-in failed: \(reason)"
        }
    }
}

enum CognitoOAuthRequest {
    static func authorizationURL(
        configuration: CognitoOAuthConfiguration,
        state: String,
        codeChallenge: String
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = configuration.domain
        components.path = "/oauth2/authorize"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    static func authorizationCodeForm(
        configuration: CognitoOAuthConfiguration,
        code: String,
        codeVerifier: String
    ) -> String {
        formEncoded([
            "grant_type": "authorization_code",
            "client_id": configuration.clientID,
            "code": code,
            "redirect_uri": configuration.redirectURI,
            "code_verifier": codeVerifier,
        ])
    }

    static func refreshTokenForm(
        configuration: CognitoOAuthConfiguration,
        refreshToken: String
    ) -> String {
        formEncoded([
            "grant_type": "refresh_token",
            "client_id": configuration.clientID,
            "refresh_token": refreshToken,
        ])
    }

    static func formEncoded(_ values: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = values.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        return components.percentEncodedQuery ?? ""
    }
}

enum CognitoPKCE {
    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum CognitoOAuthCallback {
    static func authorizationCode(from url: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CognitoOAuthError.missingAuthorizationCode
        }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        guard values["state"] == expectedState else {
            throw CognitoOAuthError.invalidState
        }
        if let error = values["error"], !error.isEmpty {
            throw CognitoOAuthError.authorizationFailed(error)
        }
        guard let code = values["code"], !code.isEmpty else {
            throw CognitoOAuthError.missingAuthorizationCode
        }
        return code
    }
}

struct CognitoStoredTokens: Codable, Sendable {
    let idToken: String?
    let refreshToken: String
    let expiresAt: Date

    func requiresRefresh(at date: Date) -> Bool {
        idToken?.isEmpty != false || expiresAt.timeIntervalSince(date) <= 60
    }
}

struct CognitoOAuthTokenResponse: Codable, Sendable {
    let idToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }

    func storedTokens(previousRefreshToken: String?, now: Date) -> CognitoStoredTokens {
        CognitoStoredTokens(
            idToken: idToken,
            refreshToken: refreshToken ?? previousRefreshToken ?? "",
            expiresAt: now.addingTimeInterval(TimeInterval(expiresIn))
        )
    }
}
