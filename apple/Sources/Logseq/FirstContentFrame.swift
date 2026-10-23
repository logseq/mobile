import UIKit

@MainActor final class LogseqFirstContentFrame: NSObject {
    private var updateLink: AnyObject?
    private var displayLink: CADisplayLink?
    private var onCommit: (@MainActor () -> Void)?
    private var completed = false
    private var displayTicks = 0

    func observe(in window: UIWindow, onCommit: @escaping @MainActor () -> Void) {
        guard !completed, self.onCommit == nil else { return }
        self.onCommit = onCommit
        if #available(iOS 18.0, *), let scene = window.windowScene {
            let link = UIUpdateLink(windowScene: scene)
            link.addAction(to: .afterCATransactionCommit) { [weak self] _, _ in
                self?.complete()
            }
            updateLink = link
            link.isEnabled = true
        } else {
            // A second display tick observes a completed update on iOS 17.
            let link = CADisplayLink(target: self, selector: #selector(displayTick))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    @objc private func displayTick() {
        displayTicks += 1
        if displayTicks >= 2 { complete() }
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        if #available(iOS 18.0, *), let link = updateLink as? UIUpdateLink {
            link.isEnabled = false
        }
        updateLink = nil
        displayLink?.invalidate()
        displayLink = nil
        let callback = onCommit
        onCommit = nil
        callback?()
    }
}
