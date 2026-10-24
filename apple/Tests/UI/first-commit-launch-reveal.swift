import SwiftUI
import UIKit
import Logseq

@main struct FirstCommitLaunchRevealCheck {
    @MainActor static func main() async throws {
        UserDefaults.standard.set("http://127.0.0.1:1", forKey: "logseq.baseURL")
        LogseqAppDelegate.shared.onInit()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: LogseqRootView())
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        guard let cover = window.subviews.first(where: { $0.accessibilityIdentifier == "launch.transition" }) else {
            throw NSError(domain: "FirstCommitLaunchReveal", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The actual application root did not mount its launch transition during layout"])
        }
        guard cover.backgroundColor?.cgColor.alpha == 0 else {
            throw NSError(domain: "FirstCommitLaunchReveal", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Ready root content must be revealed in its first layer transaction, without another main-queue turn"])
        }
        guard !cover.isUserInteractionEnabled, cover.subviews.compactMap({ $0 as? UIImageView }).first != nil else {
            throw NSError(domain: "FirstCommitLaunchReveal", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The independent logo fade must remain noninteractive"])
        }
        print("PASS: actual application root reveals its ready content in the first layer transaction")
    }
}
