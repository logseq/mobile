import UIKit
import QuartzCore

@MainActor final class LogseqFirstContentFrame: NSObject {
    private var updateLink: AnyObject?
    private var displayLink: CADisplayLink?
    private var onDisplay: (@MainActor () -> Void)?
    private var completed = false
    private var displayTicks = 0
    private weak var window: UIWindow?
    private var presentationTime: CFTimeInterval?

    func observe(in window: UIWindow, onDisplay: @escaping @MainActor () -> Void) {
        guard !completed, self.onDisplay == nil else { return }
        self.window = window
        self.onDisplay = onDisplay
        displayTicks = 0
        presentationTime = nil
        if #available(iOS 18.0, *), let scene = window.windowScene {
            let link = UIUpdateLink(windowScene: scene)
            link.addAction(to: .afterCATransactionCommit) { [weak self] link, info in
                guard let self, let window = self.window,
                      !LogseqLaunchTransition.shared.isCoveringContent(in: window) else { return }
                self.presentationTime = max(CACurrentMediaTime(), info.estimatedPresentationTime)
                link.isEnabled = false
            }
            updateLink = link
            link.isEnabled = true
        }
        let link = CADisplayLink(target: self, selector: #selector(displayTick))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func displayTick() {
        guard let window else {
            stopObserving()
            onDisplay = nil
            return
        }
        guard !LogseqLaunchTransition.shared.isCoveringContent(in: window) else {
            displayTicks = 0
            return
        }
        if updateLink != nil {
            guard let presentationTime, let displayLink,
                  displayLink.timestamp >= presentationTime else { return }
        } else {
            // Without UIUpdateLink, a second uncovered tick observes a completed update.
            displayTicks += 1
            guard displayTicks >= 2 else { return }
        }
        complete()
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        stopObserving()
        let callback = onDisplay
        onDisplay = nil
        callback?()
    }

    private func stopObserving() {
        if #available(iOS 18.0, *), let link = updateLink as? UIUpdateLink {
            link.isEnabled = false
        }
        updateLink = nil
        displayLink?.invalidate()
        displayLink = nil
        window = nil
    }
}
