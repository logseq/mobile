import Foundation

public struct LGDiscussionPushPreferences: Codable, Sendable {
    var enabled: Bool
    var comments: Bool
    var reactions: Bool
}

#if os(iOS)
import UIKit
import UserNotifications

@MainActor public final class LGDiscussionPush {
    public static let shared = LGDiscussionPush()

    private let defaults = UserDefaults.standard
    private let preferenceKey = "logseq.discussionPush.enabled"
    private let commentsKey = "logseq.discussionPush.comments"
    private let reactionsKey = "logseq.discussionPush.reactions"
    private let installationKey = "logseq.discussionPush.installation"
    private var tokenContinuation: CheckedContinuation<Data, Error>?
    private var tokenTimeout: Task<Void, Never>?
    private var updating = false

    var preferences: LGDiscussionPushPreferences {
        LGDiscussionPushPreferences(enabled: defaults.bool(forKey: preferenceKey),
            comments: defaults.object(forKey: commentsKey) as? Bool ?? true,
            reactions: defaults.object(forKey: reactionsKey) as? Bool ?? true)
    }

    var preferencePayload: String {
        guard let data = try? JSONEncoder().encode(preferences) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func save(_ value: LGDiscussionPushPreferences) {
        defaults.set(value.enabled, forKey: preferenceKey)
        defaults.set(value.comments, forKey: commentsKey)
        defaults.set(value.reactions, forKey: reactionsKey)
    }

    private var installationID: String {
        if let value = defaults.string(forKey: installationKey) { return value }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: installationKey)
        return value
    }

    public func registered(deviceToken: Data) {
        tokenTimeout?.cancel()
        tokenContinuation?.resume(returning: deviceToken)
        tokenContinuation = nil
    }

    public func registrationFailed(_ error: any Error) {
        tokenTimeout?.cancel()
        tokenContinuation?.resume(throwing: error)
        tokenContinuation = nil
    }

    private func deviceToken() async throws -> Data {
        guard tokenContinuation == nil else { throw PushError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            tokenContinuation = continuation
            tokenTimeout = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(12))
                    self?.registrationFailed(PushError.unavailable)
                } catch is CancellationError {}
                catch {}
            }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func setPreferences(_ value: LGDiscussionPushPreferences, sessionToken: String?) async throws {
        guard !updating else { throw PushError.unavailable }
        updating = true
        defer { updating = false }
        if value.enabled {
            guard let sessionToken else { throw PushError.unavailable }
            if !preferences.enabled {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                guard granted else { throw PushError.denied }
            }
            let token = try await deviceToken()
            try await sendRegistration(token: token, preferences: value, sessionToken: sessionToken)
        } else if preferences.enabled {
            guard let sessionToken else { throw PushError.unavailable }
            try await sendRegistration(token: nil, preferences: value, sessionToken: sessionToken)
        }
        save(value)
    }

    func refresh(sessionToken: String) async throws {
        var value = preferences
        guard value.enabled, !updating else { return }
        updating = true
        defer { updating = false }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if status == .denied {
            value.enabled = false
            try await sendRegistration(token: nil, preferences: value, sessionToken: sessionToken)
            save(value)
        } else {
            try await sendRegistration(token: deviceToken(), preferences: value, sessionToken: sessionToken)
        }
    }

    private func sendRegistration(token: Data?, preferences: LGDiscussionPushPreferences, sessionToken: String) async throws {
        guard let url = URL(string: LogseqSettingsPolicy.storedBaseURL())?.appending(path: "mobile/push-device") else {
            throw PushError.unavailable
        }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = token == nil ? "DELETE" : "PUT"
        request.setValue("Bearer " + sessionToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["installationId": installationID]
        if let token {
            body["token"] = token.map { String(format: "%02x", $0) }.joined()
            body["platform"] = Bundle.main.object(forInfoDictionaryKey: "LogseqAPNsEnvironment") as? String == "development"
              ? "apns-sandbox" : "apns"
            body["comments"] = preferences.comments
            body["reactions"] = preferences.reactions
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 204: return
        case 404: throw PushError.unsupportedServer
        default: throw PushError.unavailable
        }
    }

    private enum PushError: LocalizedError {
        case denied, unsupportedServer, unavailable
        var errorDescription: String? {
            switch self {
            case .denied: "Allow notifications in system settings"
            case .unsupportedServer: "This sync server does not support system notifications"
            case .unavailable: "System notifications are unavailable"
            }
        }
    }
}
#endif
