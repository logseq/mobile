import Foundation
import Observation

public protocol LogseqCognitoProviding: Sendable {
    // Logseq APIs require Cognito ID-token identity claims, not access-token scopes.
    // Return nil for a missing or invalid session; throw when token retrieval fails.
    func apiToken() async throws -> String?
    func signIn() async throws -> String
    func signOut() async throws
}

public enum LogseqAuthenticationState: String, Sendable {
    case restoring
    case signedOut
    case signingIn
    case signedIn
    case signingOut
}

public enum LogseqAuthenticationError: Error, LocalizedError {
    case notSignedIn

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to connect to Logseq Sync."
        }
    }
}

@MainActor @Observable public final class LogseqAuthenticationStore {
    public private(set) var state: LogseqAuthenticationState = .restoring
    public private(set) var errorMessage: String? {
        didSet {
            if let errorMessage, errorMessage != oldValue {
                LogseqRuntimeLog.shared.append(level: .error, source: .ui, message: errorMessage)
            }
        }
    }

    private let provider: any LogseqCognitoProviding
    private let onAccessToken: @MainActor (String?) -> Void

    public init(
        provider: any LogseqCognitoProviding,
        onAccessToken: @escaping @MainActor (String?) -> Void = { _ in }
    ) {
        self.provider = provider
        self.onAccessToken = onAccessToken
    }

    public func restore() async {
        state = .restoring
        errorMessage = nil
        do {
            guard let token = try await provider.apiToken(), !token.isEmpty else {
                state = .signedOut
                onAccessToken(nil)
                return
            }
            state = .signedIn
            onAccessToken(token)
        } catch {
            // A failed refresh does not establish that the stored session is invalid.
            state = .signedIn
            errorMessage = error.localizedDescription
        }
    }

    public func signIn() async {
        state = .signingIn
        errorMessage = nil
        do {
            let token = try await provider.signIn()
            guard !token.isEmpty else {
                throw LogseqAuthenticationError.notSignedIn
            }
            state = .signedIn
            onAccessToken(token)
        } catch {
            state = .signedOut
            errorMessage = error.localizedDescription
            onAccessToken(nil)
        }
    }

    public func signOut() async {
        state = .signingOut
        errorMessage = nil
        do {
            try await provider.signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
        state = .signedOut
        onAccessToken(nil)
    }

    public func apiToken() async throws -> String {
        let token: String?
        do {
            token = try await provider.apiToken()
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
        guard let token, !token.isEmpty else {
            state = .signedOut
            errorMessage = nil
            onAccessToken(nil)
            throw LogseqAuthenticationError.notSignedIn
        }
        state = .signedIn
        errorMessage = nil
        onAccessToken(token)
        return token
    }
}
