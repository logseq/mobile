import SwiftUI
import UIKit
@testable import LUIAppleBackend
@testable import Logseq

@MainActor private final class WaitingSignIn: LGEffectExecuting {
    var attempts = 0
    var finish = false
    func execute(_ effect: LGEffect) async -> LGEffectResolution {
        if effect.kind == "sign-in" {
            attempts += 1
            while !finish { try? await Task.sleep(for: .milliseconds(10)) }
            return LGEffectResolution(succeeded: true, message: "{\"__type\":\"NotAuthorizedException\"}", output: .discard)
        }
        return LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct SignInLoadingCheck {
    @MainActor static func main() async throws {
        let effects = WaitingSignIn()
        let native = LGCoreNativeCaller()
        let runtime = LGRuntime(native: native, effectExecutor: effects)
        try runtime.start(platformCode: 2, hostCode: 2, authenticationCode: 1)
        let backend = runtime.renderer.backend
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!)
        window.rootViewController = UIHostingController(rootView: LGRendererRoot(renderer: runtime.renderer))
        window.makeKeyAndVisible()
        defer { effects.finish = true; window.isHidden = true; window.rootViewController = nil; runtime.stop() }
        func descendants(_ id: Int) -> [Int] {
            [id] + (backend.model(id: id)?.children ?? backend.extensionModel(id: id)?.children ?? []).flatMap(descendants)
        }
        func find(_ identifier: String) -> Int? {
            backend.rootIDs.flatMap(descendants).first {
                backend.model(id: $0)?.property(.accessibilityIdentifier)?.stringValue == identifier
            }
        }
        func wait(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<150 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "SignInLoading", code: 1, userInfo: [NSLocalizedDescriptionKey: message + " runtime=" + (runtime.lastError ?? "none")])
        }
        try await wait("The native sign-in button must be available") { find("button.sign-in") != nil }
        try backend.performPress(node: find("button.sign-in")!)
        try await wait("The shared login form must appear") { find("field.auth.email") != nil }
        try await Task.sleep(for: .milliseconds(500))
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func save(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()!.write(to: URL.documentsDirectory.appendingPathComponent(name + ".png"))
        }
        guard let email = views(window).compactMap({ $0 as? UITextField }).first(where: { $0.keyboardType == .emailAddress }),
              let password = views(window).compactMap({ $0 as? UITextField }).first(where: { $0.isSecureTextEntry }) else {
            throw NSError(domain: "NativeAuthFieldsMissing", code: 1)
        }
        guard email.keyboardType == .emailAddress, password.isSecureTextEntry else {
            throw NSError(domain: "NativeAuthInputTraits", code: 1)
        }
        try save("auth-login-light")
        email.becomeFirstResponder()
        try await Task.sleep(for: .milliseconds(400))
        try save("auth-login-keyboard")
        window.endEditing(true)
        try backend.performPress(node: find("button.auth.create-account")!)
        try await wait("Sign-up reuses the shared form") { find("field.auth.username") != nil }
        try await Task.sleep(for: .milliseconds(300))
        try save("auth-signup-light")
        window.overrideUserInterfaceStyle = .dark
        try await Task.sleep(for: .milliseconds(300))
        try save("auth-signup-dark")
        window.overrideUserInterfaceStyle = .light
        try backend.performPress(node: find("button.auth.back")!)
        try await wait("Return to login") { find("button.auth.forgot-password") != nil }
        try backend.performPress(node: find("button.auth.forgot-password")!)
        try await wait("Password reset reuses the shared form") { find("field.auth.password") == nil }
        try await Task.sleep(for: .milliseconds(300))
        try save("auth-reset-light")
        try backend.performPress(node: find("button.auth.back")!)
        try await wait("Return to login") { find("field.auth.password") != nil }
        for _ in 0..<8 {
            try backend.performPress(node: find("button.auth.create-account")!)
            try await wait("Repeated sign-up transitions stay valid") { find("field.auth.username") != nil }
            try backend.performPress(node: find("button.auth.back")!)
            try await wait("Repeated login transitions stay valid") { find("button.auth.forgot-password") != nil }
            guard runtime.lastError == nil else { throw NSError(domain: "AuthFormPatch", code: 1) }
        }
        try backend.performTextChange(node: find("field.auth.email")!, text: "test@example.com")
        try backend.performTextChange(node: find("field.auth.password")!, text: "fixture-password")
        try await wait("Valid credentials enable submission") {
            find("button.auth.submit").flatMap { backend.model(id: $0) }?.isEnabled == true
        }
        try save("auth-login-enabled")
        try backend.performPress(node: find("button.auth.submit")!)
        try await wait("The request must show progress and prevent duplicate submissions") {
            guard let button = find("button.auth.submit") else { return false }
            return find("auth.loading") != nil && backend.model(id: button)?.isEnabled == false && effects.attempts == 1
        }
        try await Task.sleep(for: .milliseconds(200))
        guard effects.attempts == 1 else { throw NSError(domain: "DuplicateSignIn", code: 1) }
        effects.finish = true
        await runtime.drainEffectsForTesting()
        try await wait("An incorrect password must show an inline error") {
            find("auth.loading") == nil && find("auth.error") != nil
        }
        try save("auth-login-error")
        try backend.performPress(node: find("button.auth.cancel")!)
        try await wait("Closing the form dismisses the sheet") { find("sheet.authentication") == nil }
        print("PASS: shared LUI login, sign-up and reset render natively; email keyboard, secure password, progress, errors and dismissal work")
    }
}
