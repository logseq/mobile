import UIKit

@MainActor final class LogseqLaunchTransition {
    static let shared = LogseqLaunchTransition()
    private var cover: UIView?
    private var finished = false

    func show(in window: UIWindow, mode: LogseqThemeMode, darkTheme: LogseqDarkTheme) {
        guard !finished, cover == nil else { return }
        let systemStyle = window.traitCollection.userInterfaceStyle
        let style: UIUserInterfaceStyle = switch mode {
        case .system: systemStyle
        case .light: .light
        case .dark: .dark
        }
        let traits = UITraitCollection(userInterfaceStyle: style)
        guard let image = UIImage(named: "LaunchMark", in: nil, compatibleWith: traits) else { return }
        let palette = LogseqThemePolicy.palette(
            mode: mode, systemIsDark: systemStyle == .dark, darkTheme: darkTheme
        )
        let cover = UIView(frame: window.bounds)
        cover.accessibilityIdentifier = "launch.transition"
        cover.isUserInteractionEnabled = false
        cover.accessibilityElementsHidden = true
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.overrideUserInterfaceStyle = style
        cover.backgroundColor = UIColor(palette.background)
        let logoImage = style == .dark && darkTheme == .solarized
            ? image.withTintColor(
                UIColor(red: 133.0 / 255, green: 200.0 / 255, blue: 200.0 / 255, alpha: 1),
                renderingMode: .alwaysOriginal
            )
            : image
        let logo = UIImageView(image: logoImage)
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
            // Readiness reveals content promptly; the faint logo can finish independently.
            let options: UIView.AnimationOptions = [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
            UIView.animate(withDuration: 0.12, delay: 0, options: options) {
                cover.backgroundColor = .clear
            }
            UIView.animate(withDuration: 0.45, delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
                for logo in cover.subviews { logo.alpha = 0 }
            } completion: { _ in
                cover.removeFromSuperview()
            }
        }
    }
}
