import UIKit
import SwiftUI
@testable import LUIAppleBackend

@MainActor
private final class DirectedPan: UIPanGestureRecognizer {
    var horizontalVelocity: CGFloat = 0
    var verticalVelocity: CGFloat = 0
    var dragTranslation: CGFloat = 0
    var dragState: UIGestureRecognizer.State = .possible

    override var state: UIGestureRecognizer.State {
        get { dragState }
        set { dragState = newValue }
    }

    override func translation(in view: UIView?) -> CGPoint {
        CGPoint(x: dragTranslation, y: 0)
    }

    override func velocity(in view: UIView?) -> CGPoint {
        CGPoint(x: horizontalVelocity, y: verticalVelocity)
    }
}

@main
struct DrawerRapidSwipesCheck {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func main() async throws {
        let backend = LUIAppleBackend()
        try backend.apply(json: """
        {"generation":1,"ops":[
          {"op":"create-node","id":1,"kind":"root"},
          {"op":"create-node","id":2,"kind":"drawer"},
          {"op":"set-prop","id":2,"property":"selected","value":false},
          {"op":"set-prop","id":2,"property":"toggle-enabled","value":true},
          {"op":"create-node","id":3,"kind":"scroll"},
          {"op":"create-node","id":4,"kind":"button"},
          {"op":"set-prop","id":4,"property":"text","value":"Page action"},
          {"op":"create-node","id":5,"kind":"scroll"},
          {"op":"create-node","id":6,"kind":"label"},
          {"op":"set-prop","id":6,"property":"text","value":"Sidebar"},
          {"op":"insert-child","parent":1,"child":2,"index":0},
          {"op":"insert-child","parent":2,"child":3,"index":0},
          {"op":"insert-child","parent":2,"child":5,"index":1},
          {"op":"insert-child","parent":3,"child":4,"index":0},
          {"op":"insert-child","parent":5,"child":6,"index":0}
        ]}
        """)
        var generation = 1
        func select(_ selected: Bool) throws {
            generation += 1
            try backend.apply(json: """
            {"generation":\(generation),"ops":[{"op":"set-prop","id":2,"property":"selected","value":\(selected)}]}
            """)
        }
        var toggles: [Bool] = []
        var presses = 0
        var acknowledgesToggles = true
        backend.onEvent = { event in
            if case .toggleChanged(node: 2, checked: let selected) = event {
                toggles.append(selected)
                if acknowledgesToggles { try! select(selected) }
            } else if case .press(node: 4) = event {
                presses += 1
            }
        }
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            throw Failure(description: "Missing simulator window scene")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView:
            LUISwiftUIRoot(backend: backend, rootID: 1)
                .environment(\.horizontalSizeClass, .compact))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))

        func views(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(views)
        }
        guard let pan = views(window).flatMap({ $0.gestureRecognizers ?? [] })
            .first(where: { $0.name == "lui.drawer" }) as? UIPanGestureRecognizer,
              let delegate = pan.delegate, let target = delegate as? UIView else {
            throw Failure(description: "Drawer pan did not mount")
        }
        let probe = DirectedPan()
        func accepts(_ velocity: CGFloat, vertical: CGFloat = 0) -> Bool {
            probe.horizontalVelocity = velocity
            probe.verticalVelocity = vertical
            return delegate.gestureRecognizerShouldBegin?(probe) == true
        }
        // Deliver pan events to the mounted production target, including its SwiftUI
        // callbacks and backend events, without depending on synthetic touch timing.
        func drag(_ translation: CGFloat, state: UIGestureRecognizer.State) {
            probe.dragTranslation = translation
            probe.dragState = state
            probe.horizontalVelocity = 0
            target.perform(NSSelectorFromString("dragged:"), with: probe)
        }
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        // Reverse before either the native completion or the 350 ms fallback.
        for cycle in 0..<4 {
            try select(true)
            try await Task.sleep(for: .milliseconds(40))
            check(accepts(-1_500), "Closing swipe was rejected during opening animation (\(cycle))")
            check(!accepts(1_500), "An outward swipe must not close an opening drawer")
            check(!accepts(-100, vertical: 1_500), "Vertical scrolling must not become a drawer swipe")
            drag(-30, state: .began)
            drag(-320, state: .changed)
            drag(-320, state: .ended)
            try await Task.sleep(for: .milliseconds(40))
            check(toggles.last == false, "Closing swipe was swallowed during opening animation (\(cycle))")
            check(accepts(1_500), "Opening swipe was rejected during closing animation (\(cycle))")
            drag(30, state: .began)
            drag(100, state: .changed)
            try await Task.sleep(for: .milliseconds(400))
            check(!backend.allowsControlInteraction(node: 4),
                  "An old animation completion unlocked page controls during the next drag")
            drag(320, state: .changed)
            drag(320, state: .ended)
            try await Task.sleep(for: .milliseconds(40))
            check(toggles.last == true, "Opening swipe was swallowed during closing animation (\(cycle))")
        }
        try await Task.sleep(for: .milliseconds(450))
        check(backend.allowsControlInteraction(node: 4), "Page controls stayed locked after rapid swipes")
        try backend.performPress(node: 4)
        check(presses == 1, "Page controls did not recover after rapid swipes")

        // A cancelled interrupted swipe must settle and release its interaction lock.
        try select(false)
        try await Task.sleep(for: .milliseconds(40))
        drag(30, state: .began)
        drag(100, state: .changed)
        drag(100, state: .cancelled)
        try await Task.sleep(for: .milliseconds(450))
        check(backend.allowsControlInteraction(node: 4), "Cancellation left page controls locked")
        check(accepts(1_500), "Cancellation left the next opening swipe disabled")

        // The core may acknowledge the previous toggle after the next drag begins.
        acknowledgesToggles = false
        drag(30, state: .began)
        drag(320, state: .changed)
        drag(320, state: .ended)
        try await Task.sleep(for: .milliseconds(40))
        drag(-30, state: .began)
        drag(-100, state: .changed)
        try await Task.sleep(for: .milliseconds(40))
        try select(true)
        try await Task.sleep(for: .milliseconds(400))
        check(!backend.allowsControlInteraction(node: 4),
              "A delayed model acknowledgement unlocked controls during the next drag")
        drag(-320, state: .changed)
        drag(-320, state: .ended)
        try select(false)
        try await Task.sleep(for: .milliseconds(450))
        check(backend.allowsControlInteraction(node: 4), "Delayed acknowledgement left controls locked")
        if !failures.isEmpty { throw Failure(description: failures.joined(separator: "\n")) }
        print("PASS: rapid reversals, stale completions, delayed acknowledgement, cancellation, direction, and control recovery")
    }
}
