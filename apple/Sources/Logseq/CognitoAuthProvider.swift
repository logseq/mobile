import Foundation
import LogseqModel
import Security

enum CognitoAuthProviderError: Error, LocalizedError {
    case invalidConfiguration
    case invalidResponse
    case missingIDToken
    case missingRefreshToken
    case secureStorage(Int32)
    case service(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Cognito authentication is not configured."
        case .invalidResponse: "The authentication service returned an invalid response."
        case .missingIDToken: "Cognito did not return an ID token."
        case .missingRefreshToken: "Cognito did not return a refresh token."
        case .secureStorage: "Could not access the saved authentication session."
        case .service(let code): "Authentication request failed: \(code)"
        }
    }
}

struct CognitoTokenStore: Sendable {
    private let service: String

    init(service: String = "com.logseq.logseq.cognito.tokens") {
        self.service = service
    }

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

@MainActor final class CognitoAuthProvider: LogseqCognitoProviding {
    private let clientID: String
    private let tokenStore: CognitoTokenStore
    private let urlSession: URLSession
    private let endpoint: URL

    init(region: String, userPoolId: String, appClientId: String,
         tokenStore: CognitoTokenStore = CognitoTokenStore(), urlSession: URLSession = .shared,
         endpoint: URL? = nil) {
        self.clientID = appClientId
        self.tokenStore = tokenStore
        self.urlSession = urlSession
        self.endpoint = endpoint ?? URL(string: "https://cognito-idp.\(region).amazonaws.com/")!
    }

    func apiToken() async throws -> String? {
        guard let tokens = try tokenStore.load() else { return nil }
        guard !tokens.refreshToken.isEmpty else { try tokenStore.clear(); return nil }
        guard tokens.requiresRefresh(at: Date()) else { return tokens.idToken }
        do {
            let response = try await post("GetTokensFromRefreshToken", ["RefreshToken": tokens.refreshToken])
            try checkServiceError(response)
            let refreshed = try storedTokens(response, previousRefreshToken: tokens.refreshToken)
            try tokenStore.save(refreshed)
            return refreshed.idToken
        } catch CognitoAuthProviderError.service(let code)
            where code == "NotAuthorizedException" || code == "RefreshTokenReuseException" {
            try tokenStore.clear()
            return nil
        }
    }

    // OCaml owns form state and the Cognito challenge protocol. The adapter only
    // sends requests and commits complete sessions to Keychain before publishing success.
    func authenticate(_ encoded: String) async throws -> String {
        guard let request = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any],
              let operation = request["operation"] as? String,
              let body = request["body"] as? [String: Any],
              Self.interactiveOperations.contains(operation)
        else { throw CognitoAuthProviderError.invalidResponse }
        let response = try await post(operation, body)
        if response["AuthenticationResult"] != nil {
            guard operation == "InitiateAuth" || operation == "RespondToAuthChallenge" else {
                throw CognitoAuthProviderError.invalidResponse
            }
            let tokens = try storedTokens(response, previousRefreshToken: nil)
            try tokenStore.save(tokens)
            return "{\"signedIn\":true}"
        }
        // Never forward raw service messages or tokens into the UI model/logs.
        let allowed = Set(["__type", "ChallengeName", "ChallengeParameters", "Session",
                           "UserConfirmed", "CodeDeliveryDetails", "SecretCode", "Status"])
        let sanitized = response.filter { allowed.contains($0.key) }
        return String(decoding: try JSONSerialization.data(withJSONObject: sanitized), as: UTF8.self)
    }

    func signOut() async throws {
        let refreshToken = try tokenStore.load()?.refreshToken
        try tokenStore.clear()
        guard let refreshToken, !refreshToken.isEmpty else { return }
        _ = try? await post("RevokeToken", ["Token": refreshToken])
    }

    private static let interactiveOperations: Set<String> = [
        "InitiateAuth", "RespondToAuthChallenge", "SignUp", "ConfirmSignUp",
        "ResendConfirmationCode", "ForgotPassword", "ConfirmForgotPassword",
        "AssociateSoftwareToken", "VerifySoftwareToken",
    ]

    private func post(_ operation: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard !clientID.isEmpty else { throw CognitoAuthProviderError.invalidConfiguration }
        var body = body
        if operation != "AssociateSoftwareToken" && operation != "VerifySoftwareToken" {
            body["ClientId"] = clientID
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSCognitoIdentityProviderService." + operation, forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CognitoAuthProviderError.invalidResponse
        }
        if !(200..<300).contains(http.statusCode), json["__type"] == nil {
            throw CognitoAuthProviderError.service("HTTP \(http.statusCode)")
        }
        return json
    }

    private func checkServiceError(_ response: [String: Any]) throws {
        if let value = response["__type"] as? String {
            throw CognitoAuthProviderError.service(String(value.split(separator: "#").last ?? "Unknown"))
        }
    }

    private func storedTokens(_ response: [String: Any], previousRefreshToken: String?) throws -> CognitoStoredTokens {
        guard let result = response["AuthenticationResult"] as? [String: Any],
              let idToken = result["IdToken"] as? String, !idToken.isEmpty else {
            throw CognitoAuthProviderError.missingIDToken
        }
        let refreshToken = result["RefreshToken"] as? String ?? previousRefreshToken ?? ""
        guard !refreshToken.isEmpty else { throw CognitoAuthProviderError.missingRefreshToken }
        guard let expiresIn = result["ExpiresIn"] as? Double, expiresIn > 0 else {
            throw CognitoAuthProviderError.invalidResponse
        }
        return CognitoStoredTokens(idToken: idToken, refreshToken: refreshToken,
                                  expiresAt: Date().addingTimeInterval(expiresIn))
    }
}
