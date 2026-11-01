import Foundation

struct CognitoStoredTokens: Codable, Sendable {
    let idToken: String?
    let refreshToken: String
    let expiresAt: Date

    func requiresRefresh(at date: Date) -> Bool {
        idToken?.isEmpty != false || expiresAt.timeIntervalSince(date) <= 60
    }
}
