import SwiftUI

#if os(iOS)
/// A shared navigation overlay, anchored to the controller's full bounds rather
/// than the split-view detail's already-inset SwiftUI content area.
struct LGCaptureRailHost: UIViewControllerRepresentable {
    let content: AnyView
    let visible: Bool
    let dark: Bool

    func makeUIViewController(context: Context) -> Observer { Observer(content: content) }

    func updateUIViewController(_ controller: Observer, context: Context) {
        controller.enabled = visible
        controller.rail.rootView = visible ? content : AnyView(EmptyView())
        controller.rail.view.isHidden = !visible
        controller.rail.view.overrideUserInterfaceStyle = dark ? .dark : .light
        controller.attach()
    }

    static func dismantleUIViewController(_ controller: Observer, coordinator: ()) { controller.detach() }

    final class Observer: UIViewController {
        let rail: UIHostingController<AnyView>
        var enabled = false
        private var constraints: [NSLayoutConstraint] = []
        private weak var attachedNavigation: UINavigationController?

        init(content: AnyView) {
            rail = UIHostingController(rootView: content)
            super.init(nibName: nil, bundle: nil)
            rail.sizingOptions = .intrinsicContentSize
            // The native viewport anchors already account for placement. A
            // nested host must not inherit the window's side-toolbar insets.
            rail.safeAreaRegions = []
            rail.view.backgroundColor = .clear
            rail.view.accessibilityIdentifier = "navigation.capture-rail"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func loadView() { view = UIView() }
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); attach() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); attach() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); attach() }

        func attach() {
            guard enabled, let navigationController, let owner = view.window?.rootViewController,
                  navigationController.view.isDescendant(of: owner.view),
                  attachedNavigation !== navigationController || rail.parent !== owner else { return }
            detach()
            owner.addChild(rail)
            owner.view.addSubview(rail.view)
            rail.view.translatesAutoresizingMaskIntoConstraints = false
            // Own the rail outside UIKit's page stack, which replaces its child
            // controllers on push/pop. Align it to that stack's full viewport.
            rail.view.layer.zPosition = 1
            constraints = [
                rail.view.trailingAnchor.constraint(equalTo: navigationController.view.trailingAnchor, constant: -24),
                rail.view.bottomAnchor.constraint(equalTo: navigationController.view.bottomAnchor, constant: -24),
            ]
            NSLayoutConstraint.activate(constraints)
            rail.didMove(toParent: owner)
            attachedNavigation = navigationController
        }

        func detach() {
            guard rail.parent != nil else { return }
            rail.willMove(toParent: nil)
            NSLayoutConstraint.deactivate(constraints)
            constraints = []
            rail.view.removeFromSuperview()
            rail.removeFromParent()
            attachedNavigation = nil
        }
    }
}
#endif
