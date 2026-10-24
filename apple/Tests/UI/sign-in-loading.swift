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
            return LGEffectResolution(succeeded: false, message: "Authorization was cancelled", output: .discard)
        }
        return LGEffectResolution(succeeded: true, message: "", output: .discard)
    }
}

@main struct SignInLoadingCheck {
    @MainActor static func main() async throws {
        let effects = WaitingSignIn()
        let runtime = LGRuntime(native: LGCoreNativeCaller(), effectExecutor: effects)
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
            throw NSError(domain: "SignInLoading", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        try await wait("The native sign-in button must be available") { find("button.hosted-sign-in") != nil }
        try backend.performPress(node: find("button.hosted-sign-in")!)
        try await wait("Waiting for the callback must show loading and disable the button") {
            guard let button = find("button.hosted-sign-in") else { return false }
            return find("sign-in.loading") != nil && backend.model(id: button)?.isEnabled == false && effects.attempts == 1
        }
        try await Task.sleep(for: .milliseconds(200))
        guard effects.attempts == 1 else { throw NSError(domain: "DuplicateSignIn", code: 1) }
        effects.finish = true
        await runtime.drainEffectsForTesting()
        try await wait("A failed callback must stop loading and enable retry") {
            guard let button = find("button.hosted-sign-in") else { return false }
            return find("sign-in.loading") == nil && backend.model(id: button)?.isEnabled == true
                && find("text.authentication-error") != nil
        }
        print("PASS: native sign-in shows loading while awaiting a callback, prevents duplicates, and enables retry on cancellation")
    }
}
