import UIKit
import Security
import MachO
import Network
import Logseq
#if canImport(LogseqAuthenticationUI)
import LogseqAuthenticationUI
#endif

@MainActor private final class AuthenticationCallbackServer {
    private let listener: NWListener
    private let responseDelay: Duration
    private var connections: [NWConnection] = []
    private var readiness: CheckedContinuation<UInt16, Error>?

    init(responseDelay: Duration = .zero) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.responseDelay = responseDelay
    }

    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            readiness = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, let readiness = self.readiness else { return }
                    switch state {
                    case .ready:
                        self.readiness = nil
                        readiness.resume(returning: self.listener.port!.rawValue)
                    case .failed(let error):
                        self.readiness = nil
                        readiness.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    self.connections.append(connection)
                    connection.start(queue: .main)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, error in
                        guard error == nil else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: self.responseDelay)
                            let response = "HTTP/1.1 302 Found\r\nLocation: logseqbenchmarkauth://callback?code=native-success&state=expected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                                connection.cancel()
                            })
                        }
                    }
                }
            }
            listener.start(queue: .main)
        }
        return URL(string: "http://127.0.0.1:\(port)/authenticate")!
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }
}

@main struct AuthenticationLaunchCheck {
    @MainActor static func main() async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "AuthenticationLaunch", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func authenticationUILoaded() -> Bool {
            (0..<_dyld_image_count()).contains { index in
                guard let name = _dyld_get_image_name(index) else { return false }
                return String(cString: name).contains("/AuthenticationServices.framework/")
            }
        }
        try require(!authenticationUILoaded(), "Stored-session launch must not load AuthenticationServices before sign-in is requested")
        try require(Bundle.main.bundleIdentifier!.hasPrefix("com.logseq.logseq.ColdStart"),
            "Authentication checks require an isolated bundle and keychain")
        let tokens = try JSONSerialization.data(withJSONObject: [
            "idToken": "eyJhbGciOiJub25lIn0.eyJzdWIiOiJiZW5jaG1hcmsifQ.",
            "refreshToken": "unused-synthetic-refresh",
            "expiresAt": Date().addingTimeInterval(3600).timeIntervalSinceReferenceDate,
        ])
        var keychain: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.logseq.logseq.cognito.tokens", kSecAttrAccount: "current-session",
            kSecUseDataProtectionKeychain: true]
        let update = SecItemUpdate(keychain as CFDictionary, [kSecValueData: tokens] as CFDictionary)
        if update == errSecItemNotFound {
            keychain[kSecValueData] = tokens
            try require(SecItemAdd(keychain as CFDictionary, nil) == errSecSuccess, "Could not seed isolated stored credentials")
        } else { try require(update == errSecSuccess, "Could not update isolated stored credentials") }
        let runtime = LogseqLogseqRuntime.shared
        runtime.startAuthenticationRestore()
        for _ in 0..<100 where runtime.authentication.state == .restoring {
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(runtime.authentication.state == .signedIn, "The real provider must restore the synthetic unexpired session")
        try require(!authenticationUILoaded(), "Restoring credentials must leave browser authentication UI unloaded")

        #if canImport(LogseqAuthenticationUI)
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }!
        for _ in 0..<200 where UIApplication.shared.applicationState != .active {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(UIApplication.shared.applicationState == .active, "Native sign-in requires a foreground application")
        let session = LogseqWebAuthenticationSession()
        var invalidResults = 0
        do { _ = try await session.authenticate(URL(fileURLWithPath: "/tmp/authentication"), callbackScheme: "logseqbenchmarkauth", anchor: window) }
        catch { invalidResults += 1 }
        do { _ = try await session.authenticate(URL(string: "https://example.invalid")!, callbackScheme: "", anchor: window) }
        catch { invalidResults += 1 }
        try require(invalidResults == 2 && !authenticationUILoaded(), "Invalid requests must fail without loading browser UI")
        let server = try AuthenticationCallbackServer()
        let url = try await server.start()
        defer { server.stop() }
        let callback = try await session.authenticate(url, callbackScheme: "logseqbenchmarkauth", anchor: window)
        try require(callback.scheme == "logseqbenchmarkauth", "The native browser must deliver the loopback OAuth callback")
        try require(authenticationUILoaded(), "Opening sign-in must load AuthenticationServices on demand")
        let parameters = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        try require(parameters.contains(URLQueryItem(name: "code", value: "native-success")), "The authorization code must survive the native callback")
        // Let the completed native browser finish its dismissal before reopening.
        try await Task.sleep(for: .milliseconds(500))
        let delayed = try AuthenticationCallbackServer(responseDelay: .seconds(5))
        let delayedURL = try await delayed.start()
        defer { delayed.stop() }
        let pending = Task { @MainActor in
            try await session.authenticate(delayedURL, callbackScheme: "logseqbenchmarkauth", anchor: window)
        }
        try await Task.sleep(for: .milliseconds(100))
        var overlappingFailed = false
        do { _ = try await session.authenticate(delayedURL, callbackScheme: "logseqbenchmarkauth", anchor: window) }
        catch { overlappingFailed = true }
        try await Task.sleep(for: .milliseconds(400))
        session.cancel()
        session.cancel()
        let cancelled = await pending.result
        try await Task.sleep(for: .milliseconds(500))
        if case .success = cancelled { throw NSError(domain: "AuthenticationLaunch", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Cancelling must fail the pending sign-in"])
        }
        try require(overlappingFailed, "An overlapping sign-in must preserve the active request")
        let reopened = try await session.authenticate(url, callbackScheme: "logseqbenchmarkauth", anchor: window)
        try require(reopened.scheme == "logseqbenchmarkauth", "The native browser must reopen after cancellation")
        print("PASS: stored authentication leaves browser UI unloaded; native sign-in, callback, cancellation, and reopening work")
        #else
        throw NSError(domain: "AuthenticationLaunch", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The on-demand native authentication bridge is missing"])
        #endif
    }
}
