import UIKit

@MainActor final class LogseqLaunchTransition {
    static let shared = LogseqLaunchTransition()
    private var cover: UIView?
    private var finished = false

    func show(in window: UIWindow) {
        guard !finished, cover == nil, let image = UIImage(named: "LaunchLogo") else { return }
        let cover = UIView(frame: window.bounds)
        cover.accessibilityIdentifier = "launch.transition"
        cover.isUserInteractionEnabled = false
        cover.accessibilityElementsHidden = true
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.overrideUserInterfaceStyle = window.rootViewController?.traitCollection.userInterfaceStyle ?? .unspecified
        cover.backgroundColor = UIColor(named: "LaunchBackground") ?? .systemBackground
        let logo = UIImageView(image: image)
        logo.frame = cover.bounds
        logo.contentMode = .center
        logo.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.addSubview(logo)
        window.addSubview(cover)
        self.cover = cover
    }

    func finish(reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) {
        guard !finished else { return }
        finished = true
        guard let cover else { return }
        self.cover = nil
        if reduceMotion {
            cover.removeFromSuperview()
        } else {
            UIView.animate(withDuration: 0.12, delay: 0,
                options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
                cover.alpha = 0
            } completion: { _ in
                cover.removeFromSuperview()
            }
        }
    }
}
