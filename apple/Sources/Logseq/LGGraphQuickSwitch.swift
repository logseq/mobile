import LUIAppleBackend
import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor
enum LGGraphQuickSwitch {
    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(
            LUIAppleExtension(
                identifier: "graph-quick-switch",
                fingerprint: "lui-extension-v1|18:graph-quick-switch|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:11:target-name:string:required:none,12:action-label:string:required:none,9:target-id:string:required:none|events:6:switch[5:value:string:required]",
                acceptsStandardChildren: true,
                properties: [
                    .init(name: "target-id", kind: .string, isRequired: true),
                    .init(name: "target-name", kind: .string, isRequired: true),
                    .init(name: "action-label", kind: .string, isRequired: true),
                ],
                events: [.init(name: "switch", fields: [.init(name: "value", kind: .string, isRequired: true)])]
            ) { context in
                let content = context.childIDs.first.map { context.content(for: $0) } ?? AnyView(EmptyView())
                #if os(iOS)
                return AnyView(GraphSwitchSurface(context: context, content: content))
                #else
                return content
                #endif
            }
        )
    }
}

#if os(iOS)
private struct GraphSwitchSurface: View {
    let context: LUIAppleExtensionViewContext
    let content: AnyView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var distance: CGFloat = 0

    var body: some View {
        let _ = context.revision
        let target = string("target-id")
        let name = string("target-name")
        let actionLabel = string("action-label")
        content
            .background {
                LeftGraphPan(target: target) { translation in
                    if translation == 0 {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { distance = 0 }
                    } else {
                        distance = translation
                    }
                } onCommit: {
                    switchGraph(to: target)
                }
            }
            .overlay(alignment: .top) {
                if !target.isEmpty && distance > 0 {
                    Label(name, systemImage: "square.stack")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.horizontal, 24)
                        .padding(.top, 72)
                        .offset(x: reduceMotion ? 0 : max(0, 48 - distance))
                        .opacity(min(1, distance / 24))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: target) { _, _ in distance = 0 }
            .accessibilityElement(children: .contain)
            .accessibilityActions {
                if !target.isEmpty && !actionLabel.isEmpty {
                    Button(actionLabel) { switchGraph(to: target) }
                }
            }
    }

    private func switchGraph(to target: String) {
        UISelectionFeedbackGenerator().selectionChanged()
        try? context.emit(name: "switch", values: ["value": .string(target)])
    }

    private func string(_ name: String) -> String {
        if case .string(let value) = context.property(name) { return value }
        return ""
    }
}

private struct LeftGraphPan: UIViewRepresentable {
    let target: String
    let onDrag: (CGFloat) -> Void
    let onCommit: () -> Void

    func makeUIView(context: Context) -> Probe { Probe(configuration: self) }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.update(self)
    }

    static func dismantleUIView(_ probe: Probe, coordinator: ()) { probe.detach() }

    final class Probe: UIView, UIGestureRecognizerDelegate {
        private var configuration: LeftGraphPan
        private weak var host: UIView?
        private var gestureTarget: String?
        private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))

        init(configuration: LeftGraphPan) {
            self.configuration = configuration
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            pan.name = "logseq.graph-quick-switch"
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            pan.isEnabled = !configuration.target.isEmpty
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                detach()
            } else {
                attachToHost()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attachToHost()
        }

        func update(_ configuration: LeftGraphPan) {
            let previous = self.configuration.target
            self.configuration = configuration
            guard previous != configuration.target else { return }
            gestureTarget = nil
            pan.isEnabled = false
            pan.isEnabled = !configuration.target.isEmpty
        }

        private func attachToHost() {
            guard window != nil, host == nil else { return }
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController {
                    host = controller.view
                    controller.view.addGestureRecognizer(pan)
                    return
                }
                responder = current.next
            }
        }

        func detach() {
            gestureTarget = nil
            host?.removeGestureRecognizer(pan)
            host = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard !configuration.target.isEmpty, bounds.contains(touch.location(in: self)) else { return false }
            var view = touch.view
            while let current = view {
                if current is UIControl || current is UITextView || current is UITextField { return false }
                if let scroll = current as? UIScrollView,
                   scroll.isScrollEnabled,
                   scroll.contentSize.width > scroll.bounds.width + 1 {
                    return false
                }
                view = current.superview
            }
            return true
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let velocity = pan.velocity(in: host)
            return -velocity.x > abs(velocity.y) * 1.4
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let scroll = otherGestureRecognizer.view as? UIScrollView else { return false }
            return otherGestureRecognizer === scroll.panGestureRecognizer
        }

        @objc private func handle(_ pan: UIPanGestureRecognizer) {
            let distance = max(0, -pan.translation(in: host).x)
            switch pan.state {
            case .began:
                gestureTarget = configuration.target
                configuration.onDrag(distance)
            case .changed:
                configuration.onDrag(distance)
            case .ended:
                guard gestureTarget == configuration.target else { return }
                gestureTarget = nil
                let velocity = -pan.velocity(in: host).x
                let committed = distance > bounds.width * 0.3 || (distance > 30 && velocity > 650)
                configuration.onDrag(0)
                if committed { configuration.onCommit() }
            case .cancelled where gestureTarget != nil:
                gestureTarget = nil
                configuration.onDrag(0)
            default:
                break
            }
        }
    }
}
#endif
