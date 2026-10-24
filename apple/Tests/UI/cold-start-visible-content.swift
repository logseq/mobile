import UIKit

// Its runtime name deliberately matches the production title-label predicate.
@objc(OutlinerTitleLabelBenchmarkCheck) private final class BenchmarkTitleLabel: UILabel {}

@main struct VisibleContentCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }!
        let window = UIWindow(windowScene: previous.windowScene!)
        window.frame = previous.bounds
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let title = BenchmarkTitleLabel(frame: CGRect(x: 20, y: 140, width: 250, height: 40))
        title.text = "Visible journal content"
        title.isHidden = true
        controller.view.addSubview(title)
        let cover = UIView(frame: window.bounds)
        cover.accessibilityIdentifier = "launch.transition"
        cover.backgroundColor = .systemBackground
        window.addSubview(cover)
        FrameProbe.shared.start(in: window)
        // First commit is blank; the next has text hidden behind a launch cover.
        try await Task.sleep(for: .milliseconds(150))
        title.isHidden = false
        window.setNeedsLayout()
        try await Task.sleep(for: .milliseconds(150))
        Clock.mark("test_content_revealed")
        cover.backgroundColor = .clear
        window.setNeedsLayout()
        try await Task.sleep(for: .seconds(5))
        throw NSError(domain: "VisibleContentCheck", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "A visible title never produced a frame result"])
    }
}
