import Foundation

#if os(iOS)
import UIKit
import UserNotifications

@MainActor public final class LGDiscussionPush {
    public static let shared = LGDiscussionPush()

    private let defaults = UserDefaults.standard
    private let preferenceKey = "logseq.discussionPush.enabled"
    private let installationKey = "logseq.discussionPush.installation"
    private var tokenContinuation: CheckedContinuation<Data, Error>?
    private var tokenTimeout: Task<Void, Never>?

    var enabled: Bool { defaults.bool(forKey: preferenceKey) }

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

    func setEnabled(_ enabled: Bool, sessionToken: String) async throws {
        if enabled {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { throw PushError.denied }
            let token = try await deviceToken()
            try await sendRegistration(token: token, sessionToken: sessionToken)
        } else {
            try await sendRegistration(token: nil, sessionToken: sessionToken)
        }
        defaults.set(enabled, forKey: preferenceKey)
    }

    func refresh(sessionToken: String) async throws {
        guard enabled else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if status == .denied {
            try await setEnabled(false, sessionToken: sessionToken)
        } else {
            try await sendRegistration(token: deviceToken(), sessionToken: sessionToken)
        }
    }

    private func sendRegistration(token: Data?, sessionToken: String) async throws {
        guard let url = URL(string: LogseqSettingsPolicy.storedBaseURL())?.appending(path: "mobile/push-device") else {
            throw PushError.unavailable
        }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = token == nil ? "DELETE" : "PUT"
        request.setValue("Bearer " + sessionToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["installationId": installationID]
        if let token {
            body["token"] = token.map { String(format: "%02x", $0) }.joined()
            body["platform"] = Bundle.main.object(forInfoDictionaryKey: "LogseqAPNsEnvironment") as? String == "development"
              ? "apns-sandbox" : "apns"
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw PushError.unavailable }
    }

    private enum PushError: LocalizedError {
        case denied, unavailable
        var errorDescription: String? {
            switch self {
            case .denied: "Allow notifications in system settings"
            case .unavailable: "System notifications are unavailable"
            }
        }
    }
}
#endif
