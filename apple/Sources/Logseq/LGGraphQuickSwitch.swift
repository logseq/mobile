import LUIAppleBackend
import Observation
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
                fingerprint: "lui-extension-v1|18:graph-quick-switch|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:11:target-name:string:required:none,12:action-label:string:required:none,12:presentation:string:required:none,9:target-id:string:required:none|events:6:switch[5:value:string:required]",
                acceptsStandardChildren: true,
                properties: [
                    .init(name: "target-id", kind: .string, isRequired: true),
                    .init(name: "target-name", kind: .string, isRequired: true),
                    .init(name: "action-label", kind: .string, isRequired: true),
                    .init(name: "presentation", kind: .string, isRequired: true),
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
        #if os(iOS)
        try registry.register(
            LUIAppleExtension(
                identifier: "journal-graph-panes",
                fingerprint: "lui-extension-v1|19:journal-graph-panes|profiles:ios/swiftui|standard-children:1|children:|properties:12:presentation:string:required:none|events:",
                acceptsStandardChildren: true,
                properties: [.init(name: "presentation", kind: .string, isRequired: true)]
            ) { context in
                AnyView(JournalGraphPanes(context: context))
            }
        )
        #endif
    }
}

#if os(iOS)
@MainActor @Observable final class LGGraphSwitchViewport {
    var journalFrame = CGRect.null
    var composerTop: CGFloat?
    var showsNameInVerticalToolbar = false
    private(set) var feedback: GraphSwitchFeedback?

    func setFeedback(_ feedback: GraphSwitchFeedback?) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { self.feedback = feedback }
    }

    var frame: CGRect {
        guard !journalFrame.isNull, let composerTop, composerTop < journalFrame.maxY else { return journalFrame }
        var frame = journalFrame
        frame.size.height = max(0, composerTop - frame.minY)
        return frame
    }
}

extension EnvironmentValues {
    @Entry var lgGraphSwitchViewport: LGGraphSwitchViewport?
}

private struct GraphSwitchPresentation: Decodable {
    let graphID: String
    let loading: Bool
    let authentication: String
}

private struct GraphSwitchTarget: Equatable {
    let id: String
    let name: String
}

struct GraphSwitchFeedback: Identifiable {
    let id: UUID
    let name: String
    var confirmed = false
}

private struct GraphSwitchSurface: View {
    let context: LUIAppleExtensionViewContext
    let content: AnyView

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewport = LGGraphSwitchViewport()
    @State private var motion = GraphSwitchMotion()
    @State private var topInset: CGFloat = 0

    var body: some View {
        let _ = context.revision
        let target = GraphSwitchTarget(id: string("target-id"), name: string("target-name"))
        let presentation = try? JSONDecoder().decode(
            GraphSwitchPresentation.self, from: Data(string("presentation").utf8)
        )
        let actionLabel = string("action-label")
        content
            .environment(\.lgGraphSwitchViewport, viewport)
            .environment(\.lgGraphSwitchMotion, motion)
            .overlay {
                GraphSwitchTransition(
                    target: target, presentation: presentation, viewport: viewport, motion: motion,
                    active: scenePhase == .active, reduceMotion: reduceMotion,
                    onPreview: { id, name in
                        viewport.setFeedback(GraphSwitchFeedback(id: id, name: name))
                    },
                    onCommit: { id in switchGraph(to: id) },
                    onFinish: { id, succeeded in
                        guard var feedback = viewport.feedback, feedback.id == id else { return }
                        feedback.confirmed = succeeded
                        viewport.setFeedback(succeeded ? feedback : nil)
                    }
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .overlay {
                GeometryReader { geometry in
                    if viewport.showsNameInVerticalToolbar, let feedback = viewport.feedback {
                        LGGraphSwitchNameCapsule(name: feedback.name)
                            .frame(maxWidth: min(240, max(0, geometry.size.width - 192)))
                            .frame(maxWidth: .infinity)
                            .padding(.top, topInset + 4)
                    }
                }
                .allowsHitTesting(false)
            }
            .background(LGNotificationSafeAreaReader { topInset = $0 })
            .accessibilityElement(children: .contain)
            .accessibilityActions {
                if !target.id.isEmpty && !actionLabel.isEmpty {
                    Button(actionLabel) { _ = switchGraph(to: target.id) }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { viewport.setFeedback(nil) }
            }
            .task(id: viewport.feedback?.confirmed == true ? viewport.feedback?.id : nil) {
                guard let feedback = viewport.feedback, feedback.confirmed else { return }
                if UIAccessibility.isVoiceOverRunning {
                    UIAccessibility.post(notification: .announcement, argument: feedback.name)
                }
                do { try await Task.sleep(for: .milliseconds(1100)) } catch { return }
                guard viewport.feedback?.id == feedback.id else { return }
                viewport.setFeedback(nil)
            }
    }

    private func switchGraph(to target: String) -> Bool {
        do {
            try context.emit(name: "switch", values: ["value": .string(target)])
            UISelectionFeedbackGenerator().selectionChanged()
            return true
        } catch {
            return false
        }
    }

    private func string(_ name: String) -> String {
        if case .string(let value) = context.property(name) { return value }
        return ""
    }
}

struct LGGraphSwitchNameCapsule: View {
    let name: String
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private func nameLabel(font: Font) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack")
                .font(.system(size: 12))
                .accessibilityHidden(true)
            Text(name)
                .font(font)
                .lineLimit(1)
                .accessibilityIdentifier("graph-switch-name")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder var body: some View {
        let label = ViewThatFits(in: .vertical) {
            nameLabel(font: .subheadline.weight(.semibold))
            nameLabel(font: .system(size: 17, weight: .semibold))
        }
        .frame(height: 32)
        if reduceTransparency {
            label.background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        } else if #available(iOS 26.0, *) {
            label.glassEffect(.regular, in: .capsule)
        } else {
            label.background(.regularMaterial, in: Capsule())
        }
    }
}

@MainActor @Observable
private final class GraphSwitchMotion {
    struct Gesture {
        let id = UUID()
        let source: String
        let target: String
        var travel: CGFloat = 0
        var committing = false
    }

    var gesture: Gesture?
}

private extension EnvironmentValues {
    @Entry var lgGraphSwitchMotion: GraphSwitchMotion?
}

private struct JournalGraphPanes: View {
    private struct Presentation: Decodable {
        let active: String
        let visible: Bool
        let loading: Bool
        let ids: [String]
    }

    let context: LUIAppleExtensionViewContext
    @Environment(\.lgGraphSwitchMotion) private var motion
    @Environment(\.luiSemanticColors) private var colors

    private struct PaneContent: View, Equatable {
        let context: LUIAppleExtensionViewContext
        let nodeID: Int

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.nodeID == rhs.nodeID }

        var body: some View { context.content(for: nodeID) }
    }

    var body: some View {
        let _ = context.revision
        if case .string(let payload) = context.property("presentation"),
           let presentation = try? JSONDecoder().decode(Presentation.self, from: Data(payload.utf8)) {
            let panes = Array(zip(presentation.ids, context.childIDs))
            let background = colors["background"] ?? Color(uiColor: .systemBackground)
            GeometryReader { geometry in
                let width = geometry.size.width
                let gesture = presentation.visible ? motion?.gesture : nil
                ZStack(alignment: .topLeading) {
                    ForEach(panes, id: \.0) { graphID, childID in
                        let source = gesture?.source == graphID
                        let incoming = gesture?.target == graphID
                        let focused = gesture == nil && presentation.active == graphID
                        let visible = presentation.visible && (focused || source || incoming)
                        let interactive = visible && focused && !presentation.loading
                        PaneContent(context: context, nodeID: childID).equatable()
                            .frame(width: width, height: geometry.size.height)
                            .background(background)
                            .offset(x: source ? -(gesture?.travel ?? 0)
                                    : incoming ? width - (gesture?.travel ?? 0) : 0)
                            .opacity(visible ? 1 : 0)
                            .allowsHitTesting(interactive)
                            .accessibilityHidden(!interactive)
                            .transformPreference(LUIScrollTitlePreferenceKey.self) { title in
                                if !presentation.visible || presentation.active != graphID { title = nil }
                            }
                            .zIndex(source ? 2 : incoming ? 1 : 0)
                    }
                    if let gesture, !presentation.ids.contains(gesture.target) {
                        loadingPane(background, progress: gesture.committing)
                            .offset(x: width - gesture.travel)
                            .zIndex(1)
                    } else if gesture == nil && presentation.visible && presentation.loading
                                && !presentation.ids.contains(presentation.active) {
                        loadingPane(background, progress: true)
                    }
                }
                .clipped()
            }
        }
    }

    private func loadingPane(_ background: Color, progress: Bool) -> some View {
        ZStack {
            background
            if progress { ProgressView().accessibilityIdentifier("spinner.graph-loading") }
        }
        .allowsHitTesting(false)
    }
}

private struct GraphSwitchTransition: UIViewRepresentable {
    let target: GraphSwitchTarget
    let presentation: GraphSwitchPresentation?
    let viewport: LGGraphSwitchViewport
    let motion: GraphSwitchMotion
    let active: Bool
    let reduceMotion: Bool
    let onPreview: (UUID, String) -> Void
    let onCommit: (String) -> Bool
    let onFinish: (UUID, Bool) -> Void

    func makeUIView(context: Context) -> Surface { Surface(configuration: self) }
    func updateUIView(_ surface: Surface, context: Context) { surface.update(self) }
    static func dismantleUIView(_ surface: Surface, coordinator: ()) { surface.detach() }

    final class Surface: UIView, UIGestureRecognizerDelegate {
        private var configuration: GraphSwitchTransition
        private weak var host: UIView?
        private var width: CGFloat = 0
        private var surfaceSize: CGSize = .zero
        private var slideFinished = false
        private var sawLoading = false
        private var failureDeadline: Task<Void, Never>?
        private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))

        init(configuration: GraphSwitchTransition) {
            self.configuration = configuration
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            pan.name = "logseq.graph-quick-switch"
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() }
            else { attach() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attach()
            if surfaceSize != bounds.size {
                surfaceSize = bounds.size
                if let id = configuration.motion.gesture?.id {
                    DispatchQueue.main.async { [weak self] in self?.finish(id: id, succeeded: false) }
                }
            }
        }

        private func attach() {
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
            host?.removeGestureRecognizer(pan)
            host = nil
            finish(succeeded: false)
        }

        func update(_ next: GraphSwitchTransition) {
            let authenticationChanged = next.presentation?.authentication != configuration.presentation?.authentication
            configuration = next
            guard let gesture = configuration.motion.gesture else { return }
            let validSource = next.target.id == gesture.target && next.presentation?.graphID == gesture.source
            guard next.active, !authenticationChanged, gesture.committing || validSource else {
                DispatchQueue.main.async { [weak self] in self?.finish(id: gesture.id, succeeded: false) }
                return
            }
            if gesture.committing {
                sawLoading = sawLoading || next.presentation?.loading == true
                DispatchQueue.main.async { [weak self] in self?.completeIfReady(gesture.id) }
            }
        }

        private var canStart: Bool {
            configuration.active && !configuration.target.id.isEmpty
                && configuration.presentation?.loading == false
                && configuration.motion.gesture == nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard canStart, let window, configuration.viewport.frame.contains(touch.location(in: window)),
                  bounds.contains(touch.location(in: self)) else { return false }
            var view = touch.view
            while let current = view {
                if current is UIControl || current is UITextView || current is UITextField { return false }
                if let scroll = current as? UIScrollView, scroll.isScrollEnabled,
                   scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                view = current.superview
            }
            return true
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let velocity = pan.velocity(in: host)
            return canStart && -velocity.x > abs(velocity.y) * 1.4
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
            let velocity = -pan.velocity(in: host).x
            let motion = configuration.motion
            switch pan.state {
            case .began:
                guard canStart, let source = configuration.presentation?.graphID else { return }
                width = configuration.viewport.frame.width
                guard width > 0 else { return }
                let gesture = GraphSwitchMotion.Gesture(
                    source: source, target: configuration.target.id, travel: min(distance, width)
                )
                motion.gesture = gesture
                configuration.onPreview(gesture.id, configuration.target.name)
            case .changed:
                motion.gesture?.travel = min(distance, width)
            case .ended:
                guard let gesture = motion.gesture else { return }
                if distance > width * 0.3 || (distance > 30 && velocity > 650) {
                    commit(gesture)
                } else {
                    returnToSource(gesture.id)
                }
            case .cancelled, .failed:
                if let gesture = motion.gesture { returnToSource(gesture.id) }
            default:
                break
            }
        }

        private var settle: Animation? {
            configuration.reduceMotion ? nil : .smooth(duration: 0.24)
        }

        private func commit(_ gesture: GraphSwitchMotion.Gesture) {
            configuration.motion.gesture?.committing = true
            slideFinished = false
            sawLoading = false
            withAnimation(settle, completionCriteria: .removed) {
                configuration.motion.gesture?.travel = width
            } completion: { [weak self] in
                guard let self, configuration.motion.gesture?.id == gesture.id else { return }
                slideFinished = true
                completeIfReady(gesture.id)
            }
            if !configuration.onCommit(gesture.target) { returnToSource(gesture.id); return }
            failureDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !sawLoading, configuration.presentation?.graphID == gesture.source else { return }
                returnToSource(gesture.id)
            }
        }

        private func completeIfReady(_ id: UUID) {
            guard slideFinished, let gesture = configuration.motion.gesture, gesture.id == id,
                  gesture.committing, configuration.presentation?.loading == false else { return }
            if configuration.presentation?.graphID == gesture.target {
                finish(id: id, succeeded: true)
            } else if sawLoading {
                returnToSource(id)
            }
        }

        private func returnToSource(_ id: UUID) {
            guard configuration.motion.gesture?.id == id else { return }
            configuration.motion.gesture?.committing = false
            withAnimation(settle, completionCriteria: .removed) {
                configuration.motion.gesture?.travel = 0
            } completion: { [weak self] in self?.finish(id: id, succeeded: false) }
        }

        private func finish(id: UUID? = nil, succeeded: Bool) {
            guard let gesture = configuration.motion.gesture, id == nil || gesture.id == id else { return }
            failureDeadline?.cancel()
            configuration.motion.gesture = nil
            let onFinish = configuration.onFinish
            DispatchQueue.main.async { onFinish(gesture.id, succeeded) }
        }
    }
}
#endif
