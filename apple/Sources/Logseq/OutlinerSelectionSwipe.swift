#if os(iOS)
import SwiftUI
import UIKit

struct OutlinerSelectionSwipe: ViewModifier {
    let toggleSelection: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displacement: CGFloat = 0
    @GestureState private var legacyDisplacement: CGFloat = 0

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.offset(x: -displacement)
                .gesture(OutlinerLeftSwipe(track: { displacement = Self.offset(for: $0) }, finish: finish))
        } else {
            content.offset(x: -legacyDisplacement)
                .background(OutlinerLegacyScrollLock(active: legacyDisplacement > 0))
                .simultaneousGesture(DragGesture(minimumDistance: 12)
                    .updating($legacyDisplacement) { value, offset, _ in
                        let distance = -value.translation.width
                        if distance > abs(value.translation.height) * 1.5 { offset = Self.offset(for: distance) }
                    }
                    .onEnded { value in
                        let distance = -value.translation.width
                        if distance >= 44, distance > abs(value.translation.height) * 1.5 { toggleSelection() }
                    })
        }
    }

    private static func offset(for distance: CGFloat) -> CGFloat {
        let distance = max(0, distance)
        return min(distance, 72) + min(max(0, distance - 72) * 0.22, 32)
    }

    private func finish(commit: Bool) {
        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.26, dampingFraction: 0.85)) {
            displacement = 0
        }
        if commit { toggleSelection() }
    }
}

@available(iOS 18.0, *)
private struct OutlinerLeftSwipe: UIGestureRecognizerRepresentable {
    let track: (CGFloat) -> Void
    let finish: (Bool) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: nil)
            return -velocity.x > abs(velocity.y) * 1.5
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if let scroll = current as? UIScrollView, scroll.isScrollEnabled,
                   scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard let scroll = other.view as? UIScrollView else { return false }
            return other === scroll.panGestureRecognizer
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let travel = recognizer.translation(in: nil)
        let distance = -travel.x
        switch recognizer.state {
        case .began, .changed:
            track(distance)
        case .ended:
            let fastSwipe = distance >= 22 && recognizer.velocity(in: nil).x < -750
            finish(distance > abs(travel.y) * 1.5 && (distance >= 44 || fastSwipe))
        case .cancelled, .failed:
            finish(false)
        default:
            break
        }
    }
}

private struct OutlinerLegacyScrollLock: UIViewRepresentable {
    let active: Bool

    final class Coordinator {
        weak var pan: UIPanGestureRecognizer?

        func release() {
            pan?.isEnabled = true
            pan = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard active else {
            context.coordinator.release()
            return
        }
        guard context.coordinator.pan == nil else { return }
        var ancestor = view.superview
        while let current = ancestor {
            if let scroll = current as? UIScrollView, scroll.panGestureRecognizer.isEnabled {
                context.coordinator.pan = scroll.panGestureRecognizer
                scroll.panGestureRecognizer.isEnabled = false
                break
            }
            ancestor = current.superview
        }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.release()
    }
}
#endif
