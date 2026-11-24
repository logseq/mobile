import LUIAppleBackend
import SwiftUI
#if os(iOS)
import UIKit
#endif

extension EnvironmentValues {
    @Entry var logseqSidebarTranslucent = false
}

@MainActor
struct LGSidebarOverlay: View {
    let context: LUIAppleExtensionViewContext

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(LUIAppleExtension(
            identifier: "sidebar-overlay",
            fingerprint: "lui-extension-v1|15:sidebar-overlay|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:11:settings-id:int:required:none,13:dismiss-label:string:required:none,4:open:bool:required:none,5:width:int:required:none,7:enabled:bool:required:none,7:main-id:int:required:none,8:panel-id:int:required:none|events:4:open[],5:close[]",
            acceptsStandardChildren: true,
            properties: [
                .init(name: "open", kind: .bool, isRequired: true),
                .init(name: "enabled", kind: .bool, isRequired: true),
                .init(name: "width", kind: .int, isRequired: true),
                .init(name: "main-id", kind: .int, isRequired: true),
                .init(name: "panel-id", kind: .int, isRequired: true),
                .init(name: "settings-id", kind: .int, isRequired: true),
                .init(name: "dismiss-label", kind: .string, isRequired: true),
            ],
            events: [.init(name: "open", fields: []), .init(name: "close", fields: [])]
        ) { AnyView(LGSidebarOverlay(context: $0)) })
    }

    #if os(iOS)
    private var usesNativeSidebar: Bool {
        UIDevice.current.userInterfaceIdiom == .pad || Self.isDuo
    }

    private static let isDuo: Bool = {
        // Both displays on the Duo keep the existing renderer. The outer display
        // shares a compact size class with other phones.
        #if targetEnvironment(simulator)
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        #else
        var device = utsname()
        uname(&device)
        let model = withUnsafeBytes(of: &device.machine) {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        #endif
        return model == "iPhone19,4"
    }()
    #endif

    var body: some View {
        let _ = context.revision
        #if os(iOS)
        // LUI can evaluate a drawer child while reconciling a patch without mounting it.
        // Read the committed drawer children rather than IDs recorded by a child builder.
        let drawerChildren = context.childIDs.first.map { context.childIDs(of: $0) } ?? []
        if !usesNativeSidebar, drawerChildren.count == 2,
           let sidebarID = context.childIDs(of: drawerChildren[1]).first,
           context.extensionIdentifier(of: sidebarID) == "native-sidebar",
           let settingsID = context.childIDs(of: sidebarID).dropFirst().first,
           case let .int(width) = context.property("width"),
           case let .bool(open) = context.property("open"),
           case let .bool(enabled) = context.property("enabled"),
           case let .string(dismissLabel) = context.property("dismiss-label") {
            LGPhoneSidebar(
                main: context.nodeView(of: drawerChildren[0]), panel: context.nodeView(of: drawerChildren[1]),
                settings: context.nodeView(of: settingsID),
                width: CGFloat(width), open: open, enabled: enabled, dismissLabel: dismissLabel
            ) { try? context.emit(name: $0 ? "open" : "close") }
        } else {
            context.content
        }
        #else
        context.content
        #endif
    }
}

#if os(iOS)
@MainActor
private struct LGPhoneSidebar: View {
    let main: AnyView
    let panel: AnyView
    let settings: AnyView
    let width: CGFloat
    let open: Bool
    let enabled: Bool
    let dismissLabel: String
    let toggle: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var dragStart: CGFloat?
    @State private var hasOpened = false
    @State private var presentation = LGSidebarPresentation()

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = min(width, geometry.size.width * 0.80)
            let settingsInsets = EdgeInsets(
                top: 0, leading: 0,
                bottom: max(geometry.safeAreaInsets.bottom, LGNavigationSurfacePolicy.collapsedComposerCenterFromBottom - 22),
                trailing: geometry.safeAreaInsets.trailing + 16
            )
            LGSidebarLayers(
                main: AnyView(main.safeAreaPadding(.top, geometry.safeAreaInsets.top)),
                panel: panel, settings: settings, settingsInsets: settingsInsets, panelWidth: panelWidth,
                progress: progress, presentation: presentation,
                open: open, hasOpened: hasOpened, reduceMotion: reduceMotion, dismissLabel: dismissLabel,
                dismiss: { select(false) }
            )
            .background {
                LGSidebarPan(
                    canStart: { velocity in
                        let visible = presentation.progress
                        return abs(velocity.x) > 2 * abs(velocity.y) &&
                            (velocity.x > 0 ? enabled && visible < 0.99 : visible > 0.01)
                    },
                    defersToHorizontalScroll: { presentation.progress == 0 },
                    changed: { translation in
                        if dragStart == nil { dragStart = presentation.progress }
                        guard let dragStart else { return }
                        hasOpened = true
                        let fraction = translation / max(panelWidth, 1)
                        if fraction > 0 {
                            // Reveal the rows before their leading edge has crossed the whole panel width.
                            progress = 1 - (1 - dragStart) * pow(max(0, 1 - fraction), 5)
                        } else {
                            progress = max(0, dragStart + fraction)
                        }
                    },
                    ended: { translation, velocity in
                        guard let dragStart else { return }
                        self.dragStart = nil
                        let projected = dragStart + (translation + velocity * 0.16) / max(panelWidth, 1)
                        select(projected >= 0.5)
                    },
                    cancelled: {
                        dragStart = nil
                        settle(open)
                    }
                )
            }
        }
        .ignoresSafeArea(.container)
        .sensoryFeedback(.selection, trigger: open)
        .onAppear {
            progress = open ? 1 : 0
            hasOpened = open
        }
        .onChange(of: open) { _, value in
            dragStart = nil
            if progress != (value ? 1 : 0) { settle(value) }
        }
    }

    private func select(_ value: Bool) {
        guard !value || enabled || open else {
            settle(open)
            return
        }
        if value != open { toggle(value) }
        settle(value)
    }

    private func settle(_ value: Bool) {
        if value { hasOpened = true }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.30, bounce: 0)) {
            progress = value ? 1 : 0
        }
    }
}

/// Keep the displayed fraction available to a pan that interrupts a spring.
@MainActor
private final class LGSidebarPresentation {
    private(set) var progress: CGFloat = 0

    func sample(_ value: CGFloat) -> CGFloat {
        progress = min(1, max(0, value))
        return progress
    }
}

private struct LGSidebarLayers: View, Animatable {
    let main: AnyView
    let panel: AnyView
    let settings: AnyView
    let settingsInsets: EdgeInsets
    let panelWidth: CGFloat
    nonisolated var progress: CGFloat
    let presentation: LGSidebarPresentation
    let open: Bool
    let hasOpened: Bool
    let reduceMotion: Bool
    let dismissLabel: String
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.logseqDarkTheme) private var darkTheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let visible = presentation.sample(progress)
        let blocksMain = open || visible > 0.001
        let dark = colorScheme == .dark
        let palette = LogseqThemePolicy.palette(mode: .system, systemIsDark: dark, darkTheme: darkTheme)
        ZStack(alignment: .leading) {
            main
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial)
                .blur(radius: reduceTransparency ? 0 : visible * 26, opaque: true)
                .allowsHitTesting(!blocksMain)
                .accessibilityHidden(blocksMain)

            Group {
                if reduceTransparency {
                    palette.background
                } else {
                    LinearGradient(stops: [
                        .init(color: (dark ? palette.surface : palette.background).opacity(dark ? 0.68 : 0.78), location: 0),
                        .init(color: palette.background.opacity(dark ? 0.58 : 0.68), location: 0.65),
                        .init(color: palette.background.opacity(dark ? 0.36 : 0.47), location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                }
            }
            .opacity(visible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            if blocksMain {
                Button(action: dismiss) { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, panelWidth)
                    .accessibilityLabel(dismissLabel)
                    .accessibilityIdentifier("button.sidebar.dismiss")
                    .accessibilityHidden(!open)
            }

            if hasOpened {
                panel
                    .environment(\.logseqSidebarTranslucent, true)
                    .frame(width: panelWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottomTrailing) {
                        settings.padding(settingsInsets)
                    }
                    .blur(radius: reduceTransparency || visible == 0 ? 0 : 12 * (1 - visible).squareRoot())
                    .opacity(visible)
                    .offset(x: reduceMotion ? 0 : (visible - 1) * panelWidth)
                    .allowsHitTesting(open && visible > 0.95)
                    .accessibilityHidden(!open)
                    .accessibilityAction(.escape, dismiss)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct LGSidebarPan: UIViewRepresentable {
    let canStart: (CGPoint) -> Bool
    let defersToHorizontalScroll: () -> Bool
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void
    let cancelled: () -> Void

    func makeUIView(context: Context) -> Probe { Probe(self) }
    func updateUIView(_ view: Probe, context: Context) { view.handlers = self; view.attach() }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: UIView, UIGestureRecognizerDelegate {
        var handlers: LGSidebarPan
        private weak var host: UIView?
        private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))

        init(_ handlers: LGSidebarPan) {
            self.handlers = handlers
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            pan.name = "logseq.sidebar"
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attach() }
        }

        func attach() {
            guard window != nil, host == nil else { return }
            var responder: UIResponder? = next
            while let current = responder {
                if let controller = current as? UIViewController {
                    host = controller.view
                    host?.addGestureRecognizer(pan)
                    return
                }
                responder = current.next
            }
        }

        func detach() {
            host?.removeGestureRecognizer(pan)
            host = nil
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let host, handlers.canStart(pan.velocity(in: host)) else { return false }
            let location = pan.location(in: host)
            let translation = pan.translation(in: host)
            let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            guard bounds.contains(convert(start, from: host)) else { return false }
            if handlers.defersToHorizontalScroll() {
                var view = host.hitTest(start, with: nil)
                while let candidate = view {
                    if let scroll = candidate as? UIScrollView, scroll.isScrollEnabled,
                       scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                    view = candidate.superview
                }
            }
            return true
        }

        @objc private func dragged(_ pan: UIPanGestureRecognizer) {
            let translation = pan.translation(in: host).x
            switch pan.state {
            case .began, .changed: handlers.changed(translation)
            case .ended: handlers.ended(translation, pan.velocity(in: host).x)
            case .cancelled, .failed: handlers.cancelled()
            default: break
            }
        }
    }
}
#endif
