import LUIAppleBackend
import SwiftUI
#if os(iOS)
import Observation
import UIKit
#endif

enum LGNavigationSurfacePolicy {
    static let androidContentTopPadding = CGFloat(0)
    static let androidDestinationContentTopPadding = CGFloat(56)
    // The collapsed composer is 58 points tall and sits 21 points from the bottom.
    static let collapsedComposerCenterFromBottom: CGFloat = 21 + 58 / 2

    static func usesSystemGroupedBackground(contentPreference: Bool) -> Bool {
        contentPreference
    }

    static func bottomPadding(occupiesLayoutSpace: Bool) -> CGFloat {
        occupiesLayoutSpace ? CGFloat(7) : CGFloat(0)
    }

    static func systemToolbarItemWidth(
        iconWidth: CGFloat,
        minimumHitTarget: CGFloat
    ) -> CGFloat {
        max(iconWidth, minimumHitTarget)
    }
}

private extension ToolbarContent {
    @ToolbarContentBuilder
    func lgPrefersVerticalAxis() -> some ToolbarContent {
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(SwiftUI, _version: 8.1)
        if #available(iOS 27.1, *) {
            self.axisBehavior(.verticalPreferred)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

private extension EnvironmentValues {
    @Entry var lgVerticalToolbar = false
}

private struct LGToolbarAxisEnvironment: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(SwiftUI, _version: 8.1)
        if #available(iOS 27.1, *) {
            LGVerticalToolbarContent(content: content)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(SwiftUI, _version: 8.1)
@available(iOS 27.1, *)
private struct LGVerticalToolbarContent<Content: View>: View {
    let content: Content
    @Environment(\.toolbarVerticalEdge) private var verticalEdge

    var body: some View {
        content.environment(\.lgVerticalToolbar, verticalEdge != nil)
    }
}
#endif

private struct LGToolbarControlPair: View {
    let first: AnyView
    let second: AnyView

    @ViewBuilder var body: some View {
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(SwiftUI, _version: 8.1)
        if #available(iOS 27.1, *) {
            LGAdaptiveToolbarControlPair(first: first, second: second)
        } else {
            horizontalContent
        }
        #else
        horizontalContent
        #endif
    }

    private var horizontalContent: some View {
        HStack(spacing: 0) { first; second }
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(SwiftUI, _version: 8.1)
@available(iOS 27.1, *)
private struct LGAdaptiveToolbarControlPair: View {
    let first: AnyView
    let second: AnyView
    @Environment(\.toolbarVerticalEdge) private var verticalEdge

    var body: some View {
        let layout = verticalEdge == nil
            ? AnyLayout(HStackLayout(spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
        layout { first; second }
    }
}
#endif

#if os(iOS)
private struct LGDockedKeyboardInsetReader: UIViewRepresentable {
    let update: (CGFloat) -> Void

    func makeUIView(context: Context) -> Probe { Probe(update: update) }
    func updateUIView(_ view: Probe, context: Context) { view.update = update }

    final class Probe: UIView {
        var update: (CGFloat) -> Void
        private var marker: Marker?

        init(update: @escaping (CGFloat) -> Void) {
            self.update = update
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            marker?.removeFromSuperview()
            marker = nil
            guard let host = window?.rootViewController?.view else { return }
            // Observe the root view's docked guide to distinguish full-size
            // keyboards from floating keyboards without following the latter.
            host.keyboardLayoutGuide.followsUndockedKeyboard = false
            let marker = Marker { [weak self] inset in self?.update(inset) }
            marker.translatesAutoresizingMaskIntoConstraints = false
            marker.isUserInteractionEnabled = false
            host.addSubview(marker)
            NSLayoutConstraint.activate([
                marker.topAnchor.constraint(equalTo: host.keyboardLayoutGuide.topAnchor),
                marker.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                marker.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                marker.widthAnchor.constraint(equalToConstant: 1),
            ])
            self.marker = marker
        }
    }

    private final class Marker: UIView {
        let update: (CGFloat) -> Void
        private var lastInset: CGFloat = -1

        init(update: @escaping (CGFloat) -> Void) {
            self.update = update
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let host = superview else { return }
            let inset = max(0, host.bounds.maxY - host.keyboardLayoutGuide.layoutFrame.minY - host.safeAreaInsets.bottom)
            guard abs(inset - lastInset) > 0.5 else { return }
            lastInset = inset
            DispatchQueue.main.async { [weak self] in self?.update(inset) }
        }
    }
}
#endif

private struct LGSheetControlTint: ViewModifier {
    let isSwitch: Bool
    @Environment(\.luiSemanticColors) private var colors

    func body(content: Content) -> some View {
        let tint = colors["primary"] ?? LogseqThemePolicy.accent
        if isSwitch {
            content.toggleStyle(SwitchToggleStyle(tint: tint)).tint(tint)
        } else {
            content.tint(tint)
        }
    }
}

@MainActor
enum LGNavigationExtension {
    static let identifier = "native-navigation-stack"
    static let flashcardsToolbarIdentifier = "native-flashcards-toolbar"
    static let destinationIdentifier = "native-navigation-title"
    static let destinationFingerprint = "lui-tweak-v1|23:native-navigation-title|profiles:ios/swiftui|properties:5:title:string:required:none"
    static let fingerprint = "lui-extension-v1|23:native-navigation-stack|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:10:back-depth:int:required:none,16:selection-active:bool:optional:none,26:composer-dismissal-enabled:bool:required:none,28:bottom-occupies-layout-space:bool:required:none,5:depth:int:required:none,5:title:string:required:none|events:16:dismiss-composer[],16:viewport-changed[5:width:int:required],4:back[5:count:int:required]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.registerTweak(
            LUIAppleTweak(
                identifier: "sidebar-current-item",
                fingerprint: "lui-tweak-v1|20:sidebar-current-item|profiles:ios/swiftui|properties:7:current:bool:required:none",
                properties: [.init(name: "current", kind: .bool, isRequired: true)]
            ) { content, context in
                let isCurrent = context.property("current") == .bool(true)
                return AnyView(content.accessibilityAddTraits(isCurrent ? .isSelected : []))
            }
        )
        try registry.register(
            LUIAppleExtension(
                identifier: "native-auth-input",
                fingerprint: "lui-extension-v1|17:native-auth-input|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:4:kind:string:required:none|events:",
                acceptsStandardChildren: true,
                properties: [.init(name: "kind", kind: .string, isRequired: true)]
            ) { context in
                let content = context.childIDs.first.map { context.content(for: $0) } ?? AnyView(EmptyView())
                let kind: String
                if case let .string(value) = context.property("kind") { kind = value }
                else { kind = "text" }
                #if os(iOS)
                return AnyView(content
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(kind == "email" ? .emailAddress : kind == "code" ? .numberPad : .default)
                    .textContentType(kind == "email" ? .username : kind == "code" ? .oneTimeCode :
                        kind == "password" ? .password : kind == "new-password" ? .newPassword : nil)
                    .modifier(LGSheetControlTint(isSwitch: false))
                    .submitLabel(.done))
                #else
                return AnyView(content.autocorrectionDisabled())
                #endif
            }
        )
        try registry.registerTweak(
            LUIAppleTweak(
                identifier: "native-control-tint",
                fingerprint: "lui-tweak-v1|19:native-control-tint|profiles:ios/swiftui|properties:4:role:string:required:none",
                properties: [.init(name: "role", kind: .string, isRequired: true)]
            ) { content, context in
                if case .string("switch") = context.property("role") {
                    return AnyView(content.modifier(LGSheetControlTint(isSwitch: true)))
                }
                return AnyView(content.tint(.primary))
            }
        )
        try registry.registerTweak(
            LUIAppleTweak(
                identifier: "native-adaptive-insets",
                fingerprint: "lui-tweak-v1|22:native-adaptive-insets|profiles:android/kotlin,ios/swiftui|properties:10:breakpoint:int:required:none,10:wide-inset:int:required:none",
                properties: [
                    .init(name: "breakpoint", kind: .int, isRequired: true),
                    .init(name: "wide-inset", kind: .int, isRequired: true),
                ]
            ) { content, context in
                let breakpoint: CGFloat
                let wideInset: CGFloat
                if case let .int(value) = context.property("breakpoint") { breakpoint = CGFloat(value) }
                else { breakpoint = .infinity }
                if case let .int(value) = context.property("wide-inset") { wideInset = CGFloat(value) }
                else { wideInset = 0 }
                return AnyView(LGAdaptiveContentInsets(content: content, breakpoint: breakpoint, wideInset: wideInset))
            }
        )
        try registry.register(
            LUIAppleExtension(
                identifier: "native-top-notification",
                fingerprint: "lui-extension-v1|23:native-top-notification|profiles:ios/swiftui|standard-children:1|children:|properties:|events:",
                acceptsStandardChildren: true
            ) { context in
                AnyView(LGTopNotification(context: context))
            }
        )
        try registry.register(
            LUIAppleExtension(
                identifier: "native-sidebar",
                fingerprint: "lui-extension-v1|14:native-sidebar|profiles:ios/swiftui|standard-children:1|children:|properties:|events:",
                acceptsStandardChildren: true
            ) { context in
                AnyView(LGSidebarNavigation(context: context))
            }
        )
        try registry.register(
            LUIAppleExtension(
                identifier: flashcardsToolbarIdentifier,
                fingerprint: "lui-extension-v1|25:native-flashcards-toolbar|profiles:ios/swiftui|standard-children:1|children:|properties:|events:",
                acceptsStandardChildren: true
            ) { context in
                let _ = context.revision
                // The navigation stack hosts the first two children in its toolbar.
                // Render the sheet anchor in the screen's view hierarchy.
                return context.childIDs.dropFirst(2).first.map { context.content(for: $0) } ?? AnyView(EmptyView())
            }
        )
        try registry.register(
            LUIAppleExtension(
                identifier: identifier,
                fingerprint: fingerprint,
                acceptsStandardChildren: true,
                properties: [
                    .init(name: "back-depth", kind: .int, isRequired: true),
                    .init(name: "depth", kind: .int, isRequired: true),
                    .init(name: "selection-active", kind: .bool),
                    .init(name: "bottom-occupies-layout-space", kind: .bool, isRequired: true),
                    .init(name: "composer-dismissal-enabled", kind: .bool, isRequired: true),
                    .init(name: "title", kind: .string, isRequired: true),
                ],
                events: [
                    .init(name: "back", fields: [
                        .init(name: "count", kind: .int, isRequired: true),
                    ]),
                    .init(name: "dismiss-composer", fields: []),
                    .init(name: "viewport-changed", fields: [
                        .init(name: "width", kind: .int, isRequired: true),
                    ]),
                ]
            ) { context in
                AnyView(LGNavigationStack(context: context))
            }
        )
        try registry.registerTweak(
            LUIAppleTweak(
                identifier: destinationIdentifier,
                fingerprint: destinationFingerprint,
                properties: [
                    .init(name: "title", kind: .string, isRequired: true),
                ]
            ) { content, context in
                AnyView(LGNavigationDestination(context: context, content: content))
            }
        )
    }
}

private struct LGTopNotification: View {
    let context: LUIAppleExtensionViewContext
    @State private var topInset: CGFloat?

    var body: some View {
        let _ = context.revision
        Group {
            if let child = context.childIDs.first { context.content(for: child) }
        }
        .padding(.top, topInset ?? 0)
        .opacity(topInset == nil ? 0 : 1)
        #if os(iOS)
        .background(LGWindowVerticalInsetsReader { topInset = $0.top })
        #else
        .onAppear { topInset = 0 }
        #endif
    }
}

#if os(iOS)
struct LGWindowVerticalInsetsReader: UIViewRepresentable {
    let update: (UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> Probe { Probe(update: update) }
    func updateUIView(_ view: Probe, context: Context) { view.measure() }

    final class Probe: UIView {
        let update: (UIEdgeInsets) -> Void
        private var reported: UIEdgeInsets?
        init(update: @escaping (UIEdgeInsets) -> Void) {
            self.update = update
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); measure() }
        override func layoutSubviews() { super.layoutSubviews(); measure() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); measure() }
        func measure() {
            guard let window else { return }
            // A full-window drawer scales during transitions without changing its layout insets.
            let frame = abs(bounds.height - window.bounds.height) < 1
                ? window.bounds : convert(bounds, to: window)
            let insets = UIEdgeInsets(top: max(0, window.safeAreaInsets.top - frame.minY),
                                      left: 0,
                                      bottom: max(0, frame.maxY - (window.bounds.maxY - window.safeAreaInsets.bottom)),
                                      right: 0)
            guard insets != reported else { return }
            reported = insets
            DispatchQueue.main.async { [update] in update(insets) }
        }
    }
}
#endif

private struct LGSidebarNavigation: View {
    private static let settingsButtonHeight: CGFloat = 44
    let context: LUIAppleExtensionViewContext
    @AppStorage("logseq.appearance") private var appearance = "system"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.logseqDarkTheme) private var darkTheme
    @State private var topInset: CGFloat = 0

    private var settingsBottomPadding: CGFloat {
        LGNavigationSurfacePolicy.collapsedComposerCenterFromBottom - Self.settingsButtonHeight / 2
    }

    private var palette: LogseqThemePalette {
        LogseqThemePolicy.palette(
            mode: LogseqThemeMode(rawValue: appearance) ?? .system,
            systemIsDark: colorScheme == .dark,
            darkTheme: darkTheme
        )
    }

    var body: some View {
        let _ = context.revision
        let palette = palette
        let background = palette.background
        let selectionTint = palette.backgroundHex == LogseqThemePolicy.black.backgroundHex
            ? Color.white
            : LogseqThemePolicy.accent
        let scroll = ScrollView {
            child(at: 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Let the rows scroll into the status area while starting just below it.
                .padding(.top, topInset)
                .padding(.bottom, settingsBottomPadding + Self.settingsButtonHeight + 4)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("scroll.sidebar.pages")
        .accentColor(selectionTint)
        Group {
            #if os(iOS)
            if #available(iOS 26.0, *) {
                scroll
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .scrollEdgeEffectHidden(true, for: .bottom)
            } else {
                scroll
            }
            #else
            scroll
            #endif
        }
        .overlay(alignment: .bottomTrailing) {
            child(at: 1)
                .padding(.trailing, 16)
                .padding(.bottom, settingsBottomPadding)
        }
        #if os(iOS)
        .background(LGWindowVerticalInsetsReader { topInset = $0.top })
        #endif
        .background(background.ignoresSafeArea())
    }

    private func child(at index: Int) -> AnyView {
        let children = context.childIDs
        guard children.indices.contains(index) else { return AnyView(EmptyView()) }
        return context.content(for: children[index])
    }
}

@MainActor
private struct LGNavigationStack: View {
    let context: LUIAppleExtensionViewContext

    var body: some View {
        LGNavigationContent(
            context: context,
            rootIndex: 0,
            synchronizationName: "navigation",
            toolbarStartIndex: 1,
            trailingMenuIndex: nil,
            bottomChromeIndex: 5,
            rootTransform: nil
        )
        .onGeometryChange(for: Int.self) { geometry in
            Int(geometry.size.width.rounded(.down))
        } action: { width in
            try? context.emit(name: "viewport-changed", values: ["width": .int(width)])
        }
        .modifier(LGToolbarAxisEnvironment())
    }

}

private struct LGNavigationDestination: View {
    let context: LUIAppleExtensionViewContext
    let content: AnyView
    @State private var visibleScrollTitle: String?

    var body: some View {
        let _ = context.revision
        content
            .navigationTitle(title.isEmpty ? visibleScrollTitle ?? "" : title)
            .onPreferenceChange(LUIScrollTitlePreferenceKey.self) { visibleScrollTitle = $0 }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }

    private var title: String {
        guard case let .string(value) = context.property("title") else { return "" }
        return value
    }
}

@MainActor
enum LGSearchPresentationExtension {
    static let identifier = "native-search-presentation"
    static let fingerprint = "lui-extension-v1|26:native-search-presentation|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:10:back-title:string:optional:none,11:clear-title:string:optional:none,11:close-title:string:optional:none,12:status-title:string:optional:none,28:bottom-occupies-layout-space:bool:required:none,5:depth:int:required:none,5:query:string:required:none,5:title:string:required:none,9:presented:bool:required:none|events:13:query-changed[5:query:string:required],4:back[5:count:int:required],7:dismiss[],7:present[]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(
            LUIAppleExtension(
                identifier: identifier,
                fingerprint: fingerprint,
                acceptsStandardChildren: true,
                properties: [
                    .init(name: "back-title", kind: .string),
                    .init(name: "clear-title", kind: .string),
                    .init(name: "close-title", kind: .string),
                    .init(name: "bottom-occupies-layout-space", kind: .bool, isRequired: true),
                    .init(name: "presented", kind: .bool, isRequired: true),
                    .init(name: "depth", kind: .int, isRequired: true),
                    .init(name: "query", kind: .string, isRequired: true),
                    .init(name: "status-title", kind: .string),
                    .init(name: "title", kind: .string, isRequired: true),
                ],
                events: [
                    .init(name: "back", fields: [
                        .init(name: "count", kind: .int, isRequired: true),
                    ]),
                    .init(name: "dismiss", fields: []),
                    .init(name: "present", fields: []),
                    .init(name: "query-changed", fields: [
                        .init(name: "query", kind: .string, isRequired: true),
                    ]),
                ]
            ) { context in
                AnyView(LGSearchPresentation(context: context))
            }
        )
    }
}

@MainActor
@Observable
private final class LGNativeSearchState {
    private enum Phase { case inactive, active }
    let context: LUIAppleExtensionViewContext
    private var phase = Phase.inactive
    // Keep the content tree stable while UIKit moves its keyboard and toolbar.
    @ObservationIgnored private var isClosing = false
    private var pendingQuery: String?
    private(set) var nativePresented = false

    init(context: LUIAppleExtensionViewContext) { self.context = context }

    var isVisible: Bool { phase == .active }
    var resultsAreVisible: Bool { nativePresented || !isClosing }
    var corePresented: Bool {
        guard case let .bool(value) = context.property("presented") else { return false }
        return value
    }
    var depth: Int {
        guard case let .int(value) = context.property("depth") else { return 0 }
        return value
    }
    var title: String {
        guard case let .string(value) = context.property("title") else { return "Search" }
        return value
    }
    var query: String {
        guard case let .string(value) = context.property("query") else { return "" }
        return value
    }
    var statusTitle: String {
        guard case let .string(value) = context.property("status-title") else { return title }
        return value
    }

    func synchronizeCore() {
        if corePresented {
            guard !isClosing else { return }
            if phase != .active { pendingQuery = nil }
            phase = .active
            nativePresented = depth == 0
        } else {
            phase = .inactive
            isClosing = false
            nativePresented = false
            pendingQuery = nil
        }
    }

    func synchronizeDepth() {
        if isVisible && depth == 0 { nativePresented = true }
    }
    func suspendInput() {
        if depth > 0 { nativePresented = false }
    }
    func acknowledgeQuery() { if pendingQuery == query { pendingQuery = nil } }

    private func open() {
        nativePresented = true
        isClosing = false
        guard phase != .active else { return }
        phase = .active
        pendingQuery = nil
        try? context.emit(name: "present", values: [:])
    }

    func close() {
        guard phase == .active else { return }
        isClosing = true
    }

    func nativeWillDismiss() {
        nativePresented = false
        if depth == 0 { close() }
    }

    func finishDismissal() {
        // Let UIKit commit the keyboard and toolbar transition before core cleanup.
        Task { @MainActor in
            guard self.isClosing else { return }
            self.phase = .inactive
            self.nativePresented = false
            if self.corePresented { try? self.context.emit(name: "dismiss", values: [:]) }
            self.isClosing = false
        }
    }

    var presentationBinding: Binding<Bool> {
        presentationBinding(onDismiss: finishDismissal)
    }

    func presentationBinding(onDismiss: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { self.nativePresented }, set: { value in
            if value { self.open() }
            else {
                self.nativePresented = false
                if self.depth == 0 {
                    self.close()
                    onDismiss()
                }
            }
        })
    }

    var queryBinding: Binding<String> {
        Binding(get: { self.pendingQuery ?? self.query }, set: { value in
            guard self.isVisible, !self.isClosing, self.nativePresented else { return }
            self.pendingQuery = value
            // Native Cancel clears text too. Its dismissal must win over that change.
            Task { @MainActor in
                guard self.isVisible, !self.isClosing, self.nativePresented, self.pendingQuery == value else { return }
                try? self.context.emit(name: "query-changed", values: ["query": .string(value)])
            }
        })
    }
}

private extension EnvironmentValues {
    @Entry var logseqNativeSearch: LGNativeSearchState? = nil
}

@MainActor
private struct LGSearchPresentation: View {
    let context: LUIAppleExtensionViewContext
    @State private var search: LGNativeSearchState

    init(context: LUIAppleExtensionViewContext) {
        self.context = context
        _search = State(initialValue: LGNativeSearchState(context: context))
    }

    var body: some View {
        let _ = context.revision
        Group {
            if let child = context.childIDs.first { context.content(for: child) }
        }
        .environment(\.logseqNativeSearch, search)
        .onChange(of: search.corePresented, initial: true) { search.synchronizeCore() }
        .onChange(of: search.depth) { search.synchronizeDepth() }
        .onChange(of: search.query) { search.acknowledgeQuery() }
    }
}

private struct LGNativeSearchHost: ViewModifier {
    let search: LGNativeSearchState?
    #if os(iOS)
    let transitions: LGNavigationTransitions
    #endif
    @ViewBuilder
    func body(content: Content) -> some View {
        if let search {
            let _ = search.context.revision
            Group {
                #if os(iOS)
                let _ = search.nativePresented
                if #available(iOS 26.0, *) {
                    content
                        .background(LGNativeSearchControllerBridge(search: search).allowsHitTesting(false))
                } else {
                    content
                        .background {
                            if search.nativePresented {
                                Color.clear.searchable(
                                    text: search.queryBinding,
                                    isPresented: search.presentationBinding {
                                        transitions.afterSearchDismissal(search.finishDismissal)
                                    },
                                    placement: .navigationBarDrawer(displayMode: .always),
                                    prompt: Text(search.title)
                                )
                            }
                        }
                        .onChange(of: search.nativePresented) { _, presented in
                            LogseqCrashReporting.uiState(nativeSearchActive: presented)
                        }
                }
                #else
                content.searchable(text: search.queryBinding, isPresented: search.presentationBinding,
                    placement: .automatic, prompt: Text(search.title))
                #endif
            }
        } else { content }
    }
}

@MainActor
private struct LGNativeNavigationPop {
    let original: [Int]
    let target: [Int]

    func awaitsAcknowledgement(_ desired: [Int]) -> Bool {
        desired.count >= target.count && original.starts(with: desired) && desired != target
    }
}

private struct LGNavigationContent: View {
    let context: LUIAppleExtensionViewContext
    let rootIndex: Int
    let synchronizationName: String
    let toolbarStartIndex: Int?
    let trailingMenuIndex: Int?
    let bottomChromeIndex: Int?
    let rootTransform: ((AnyView) -> AnyView)?
    @State private var nativePop: LGNativeNavigationPop?
    @State private var minimumScrollViewport: CGRect?
    #if os(iOS)
    @State private var transitions = LGNavigationTransitions()
    @State private var outlinerToolbarReserve = OutlinerToolbarReserve()
    @State private var dockedKeyboardInset: CGFloat = 0
    #endif
    @State private var usesSystemGroupedBackground = false
    @State private var visibleScrollTitle: String?
    @Namespace private var trailingGlass
    @AppStorage("logseq.appearance") private var appearance = "system"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.logseqDarkTheme) private var darkTheme
    @Environment(\.logseqNativeSearch) private var inheritedSearch
    @Environment(\.lgVerticalToolbar) private var verticalToolbar
    @Environment(\.lgPDFWorkspaceOpen) private var pdfWorkspaceOpen
    @Environment(\.lgPDFMainHidden) private var pdfMainHidden
    @Environment(\.luiSemanticColors) private var semanticColors
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var search: LGNativeSearchState? { toolbarStartIndex == nil ? nil : inheritedSearch }
    private func nativeSearchHost(_ search: LGNativeSearchState?) -> LGNativeSearchHost {
        #if os(iOS)
        LGNativeSearchHost(search: search, transitions: transitions)
        #else
        LGNativeSearchHost(search: search)
        #endif
    }
    private var searchVisible: Bool { search?.isVisible == true }
    private var searchRoutes: [Int] {
        guard searchVisible, let search else { return [] }
        return pageRoutes(in: search.context, depth: search.depth)
    }
    private var showsSearchPage: Bool { searchVisible && (search?.depth ?? 0) > 0 }
    private var chromeContext: LUIAppleExtensionViewContext { showsSearchPage ? search!.context : context }
    private var showsBottomChrome: Bool { !searchVisible || showsSearchPage || hasCollapsedComposer }

    private var selectionActive: Bool {
        if case .bool(true) = context.property("selection-active") { return true }
        return false
    }

    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    private var captureActionIDs: [Int] {
        // The final child owns the shared camera/audio/search/capture actions; routes
        // retain their existing slots before this stable container.
        guard toolbarStartIndex != nil, context.childIDs.count >= 7,
              let container = context.childIDs.last else { return [] }
        let _ = context.measureStamp(of: container)
        let actions = context.childIDs(of: container)
        return actions.count == 4 ? actions : []
    }

    private var usesSideCaptureActions: Bool {
        verticalToolbar && !selectionActive && hasCollapsedComposer && captureActionIDs.count == 4
    }

    private var rootTitleContent: Int? {
        guard let toolbarStartIndex,
              let titleSlot = childID(at: toolbarStartIndex + 1) else { return nil }
        let _ = context.measureStamp(of: titleSlot)
        return context.childIDs(of: titleSlot).first
    }

    private var flashcardsToolbar: (container: Int, title: Int, add: Int)? {
        guard let container = rootTitleContent,
              context.extensionIdentifier(of: container) == LGNavigationExtension.flashcardsToolbarIdentifier else { return nil }
        let children = context.childIDs(of: container)
        guard children.count == 3 else { return nil }
        return (container, children[0], children[1])
    }


    // This view observes the extension independently of its parent. Read the
    // route depth and chrome from the same live model as the child IDs.
    private var depth: Int {
        guard case let .int(value) = context.property("depth") else { return 0 }
        return value
    }

    private var hasCollapsedComposer: Bool {
        #if os(iOS)
        guard toolbarStartIndex != nil, !selectionActive, !showsSearchPage, !bottomOccupiesLayoutSpace, !composerDismissalEnabled,
              let index = bottomChromeIndex, let chrome = childID(at: index) else { return false }
        let _ = context.measureStamp(of: chrome)
        return !context.childIDs(of: chrome).isEmpty
        #else
        false
        #endif
    }

    // Collapsed and expanded composers share one placement so the swap keeps
    // layout and expansion follows the keyboard instead of jumping between branches.
    private var usesFloatingComposerChrome: Bool {
        #if os(iOS)
        hasCollapsedComposer || composerDismissalEnabled
        #else
        false
        #endif
    }

    private var bottomOccupiesLayoutSpace: Bool {
        guard case let .bool(value) = chromeContext.property("bottom-occupies-layout-space") else { return false }
        return value
    }

    private var composerDismissalEnabled: Bool {
        guard case let .bool(value) = context.property("composer-dismissal-enabled") else { return false }
        return value
    }

    // A mirrored @State path changes navigation twice in the same render frame.
    // Read core routes directly, retaining only native pops awaiting core acknowledgement.
    private var path: [Int] {
        let desired = desiredPath
        if let nativePop, nativePop.awaitsAcknowledgement(desired) { return nativePop.target }
        return desired
    }

    @ViewBuilder
    var body: some View {
        let _ = context.revision
        let _ = search?.context.revision
        navigationStack
            #if os(iOS)
            .environment(\.outlinerToolbarReserve, outlinerToolbarReserve)
            #endif
            .environment(\.luiMinimumScrollViewport, minimumScrollViewport)
            .background {
                GeometryReader { _ in
                    Color.clear
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            minimumScrollViewport = frame
                        }
                }
                .ignoresSafeArea(.all, edges: .bottom)
            }
            .onPreferenceChange(LUIListSurfacePreferenceKey.self) { usesSystemBackground in
                usesSystemGroupedBackground = usesSystemBackground
            }
            .onPreferenceChange(LUIScrollTitlePreferenceKey.self) { title in
                if !searchVisible { visibleScrollTitle = title }
            }
    }

    @ViewBuilder
    private func navigationSurface<Content: View>(_ content: Content, active: Bool) -> some View {
        let surface = content
            .overlay {
                if active && composerDismissalEnabled {
                    composerDismissalTarget
                }
            }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    if active && showsBottomChrome && !usesSideCaptureActions {
                        if bottomOccupiesLayoutSpace {
                            // The measured toolbar guides caret avoidance without resizing the scroller.
                            sizedBottomChrome
                        } else if selectionActive {
                            VStack {
                                Spacer(minLength: 0)
                                floatingBottomChrome
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea(.all, edges: .bottom)
                            .transition(.opacity)
                        } else if usesFloatingComposerChrome {
                            VStack {
                                Spacer(minLength: 0)
                                floatingBottomChrome
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea(hasCollapsedComposer ? .all : .container, edges: .bottom)
                            // Keep capture controls mounted underneath the native search surface.
                            .opacity(searchVisible ? 0 : 1)
                            .animation(nil, value: searchVisible)
                            .allowsHitTesting(!searchVisible)
                            .accessibilityHidden(searchVisible)
                            .transition(.opacity)
                        } else {
                            sizedBottomChrome
                        }
                    }
                }
                .animation(selectionAnimation, value: selectionActive)
            }
            #if os(iOS)
            // Docked keyboards already resize the native navigation container.
            // Only floating keyboards bypass avoidance to keep the toolbar fixed.
            .ignoresSafeArea(.keyboard, edges: UIDevice.current.userInterfaceIdiom == .pad && !hasCollapsedComposer && dockedKeyboardInset == 0 ? .bottom : [])
            .background {
                if active && UIDevice.current.userInterfaceIdiom == .pad && !hasCollapsedComposer {
                    LGDockedKeyboardInsetReader { dockedKeyboardInset = $0 }
                }
            }
            #endif
            .background(routeBackground.ignoresSafeArea())
        #if os(iOS)
        if #available(iOS 26.0, *) {
            surface
                .toolbarBackground(.hidden, for: .navigationBar)
                // The scroll edge supplies the blur while the system bar stays clear.
                // Duo's vertical toolbar has no horizontal edge effect.
                .scrollEdgeEffectHidden(true, for: verticalToolbar ? .all : .bottom)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            surface.toolbarBackground(.hidden, for: .navigationBar)
        }
        #else
        surface
        #endif
    }

    private var composerDismissalTarget: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: dismissComposerFromTap)
            .accessibilityLabel("Dismiss composer")
            .accessibilityIdentifier("surface.composer.dismiss")
    }

    private var navigationStack: some View {
        // Keep returning content mounted while UISearchController animates its toolbar.
        NavigationStack(path: pathBinding) {
            navigationSurface(Group {
                if toolbarStartIndex != nil {
                    rootNavigationSurface.navigationTitle(verticalToolbar ? "" : contextualTitle)
                } else {
                    rootNavigationSurface
                }
            }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .background(routeBackground), active: path.isEmpty)
                .navigationDestination(for: Int.self) { childID in
                    let searchPage = searchRoutes.contains(childID)
                    let destinationSearch = searchPage ? nil : search
                    navigationSurface(destinationSurface(childID)
                        .padding(.top, destinationContentTopPadding)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .background(routeBackground), active: path.last == childID)
                        .toolbar {
                            trailingToolbar(searchPage: searchPage)
                            if !verticalToolbar, let destinationSearch, destinationSearch.isVisible {
                                ToolbarItem(placement: .principal) {
                                    searchStatusTitle(destinationSearch.statusTitle)
                                }
                            }
                        }
                        .modifier(nativeSearchHost(destinationSearch))
                        #if os(iOS)
                        .toolbar(.visible, for: .navigationBar)
                        #endif
                }
                .toolbar {
                    if let toolbarStartIndex,
                       let leadingID = childID(at: toolbarStartIndex) {
                        if !pdfWorkspaceOpen {
                            if #available(iOS 26.0, *) {
                                ToolbarItem(placement: rootLeadingToolbarPlacement) {
                                    context.content(for: leadingID)
                                        .id(context.contentRevision(for: leadingID))
                                        .modifier(LGLiquidGlassSurface(shape: .circle))
                                        .frame(width: LGNavigationSurfacePolicy.systemToolbarItemWidth(
                                            iconWidth: 24,
                                            minimumHitTarget: 44
                                        ))
                                }
                                .sharedBackgroundVisibility(.hidden)
                                .lgPrefersVerticalAxis()
                            } else {
                                ToolbarItem(placement: rootLeadingToolbarPlacement) {
                                    context.content(for: leadingID)
                                }
                            }
                        }
                        if !verticalToolbar, !pdfWorkspaceOpen || searchVisible {
                            ToolbarItem(placement: .principal) {
                                if let search, searchVisible {
                                    searchStatusTitle(search.statusTitle)
                                } else {
                                    rootHeaderTitle
                                }
                            }
                        }
                        if let flashcardsToolbar, !searchVisible {
                            let addButton = context.nodeView(of: flashcardsToolbar.add)
                                .frame(width: 44, height: 44)
                                .buttonStyle(.plain)
                            if #available(iOS 26.0, *) {
                                ToolbarItem(placement: trailingToolbarPlacement) {
                                    addButton.modifier(LGLiquidGlassSurface(shape: .circle))
                                }
                                .sharedBackgroundVisibility(.hidden)
                                .lgPrefersVerticalAxis()
                            } else {
                                ToolbarItem(placement: trailingToolbarPlacement) { addButton }
                                    .lgPrefersVerticalAxis()
                            }
                        } else {
                            trailingToolbar(searchPage: false)
                        }
                    }
                }
                .modifier(nativeSearchHost(search))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(toolbarStartIndex == nil ? .hidden : .visible, for: .navigationBar)
                #endif
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(routeBackground.ignoresSafeArea())
        #if os(iOS)
        .tint(navigationBarTint)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .onAppear {
            LGInteractionDiagnostics.event("navigation.appear", "node=\(context.nodeID) path=\(path) desired=\(desiredPath)")
        }
        .animation(.default, value: desiredPath)
        .onChange(of: desiredPath) {
            let newPath = desiredPath
            LGInteractionDiagnostics.event("navigation.change", "node=\(context.nodeID) path=\(path) desired=\(newPath) revision=\(context.revision)")
            if let nativePop, !nativePop.awaitsAcknowledgement(newPath) {
                self.nativePop = nil
            }
        }
    }

    // Toolbar closures may outlive their retained extension during root replacement.
    // Resolve each slot from one snapshot, and let removed content render empty.
    private func childID(at index: Int) -> Int? {
        let childIDs = context.childIDs
        guard childIDs.indices.contains(index) else { return nil }
        return childIDs[index]
    }

    private func childContent(at index: Int) -> AnyView {
        guard let childID = childID(at: index) else { return AnyView(EmptyView()) }
        return context.content(for: childID)
    }

    private var rootContent: AnyView {
        childContent(at: rootIndex)
    }

    private var transformedRootContent: AnyView {
        rootTransform?(rootContent) ?? rootContent
    }

    private func searchStatusTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .lineLimit(1)
            .accessibilityIdentifier("search.status")
    }

    private func graphSwitchMenu(_ nodeID: Int) -> some View {
        context.nodeView(of: nodeID)
            .lineLimit(1)
            .truncationMode(.middle)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(selectionActive)
    }

    @ViewBuilder
    private var rootHeaderTitle: some View {
        if let flashcardsToolbar {
            context.nodeView(of: flashcardsToolbar.title)
                .font(.headline)
                .lineLimit(1)
                .menuStyle(.button)
                .buttonStyle(.plain)
        } else if let graphSwitch = rootTitleContent {
            graphSwitchMenu(graphSwitch)
                .frame(minHeight: 44)
        } else if !contextualTitle.isEmpty {
            Text(verbatim: contextualTitle)
                .font(.headline)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var rootNavigationSurface: some View {
        let base = AnyView(transformedRootContent.safeAreaInset(edge: .top, spacing: 0) {
            if verticalToolbar, toolbarStartIndex != nil {
                // A principal item would create a second, horizontal bar on Duo.
                let hideTitle = searchVisible || pdfWorkspaceOpen
                rootHeaderTitle
                .frame(maxWidth: .infinity, minHeight: 44)
                .opacity(hideTitle ? 0 : 1)
                .allowsHitTesting(!hideTitle)
                .accessibilityHidden(hideTitle)
            }
        })
        withAppTint(searchSurface(base, active: path.isEmpty))
            .padding(.top, navigationContentTopPadding)
            .background {
                if let flashcardsToolbar {
                    context.nodeView(of: flashcardsToolbar.container)
                }
            }
            #if os(iOS)
            .background(LGNavigationControllerObserver(transitions: transitions).allowsHitTesting(false))
            .background {
                if toolbarStartIndex != nil {
                    LGCaptureRailHost(
                        content: AnyView(captureRail
                            .environment(\.luiSemanticColors, semanticColors)
                            .environment(\.locale, locale)
                            .environment(\.colorScheme, colorScheme)),
                        visible: usesSideCaptureActions && !searchVisible && !pdfMainHidden,
                        dark: colorScheme == .dark
                    ).allowsHitTesting(false)
                }
            }
            #endif
    }

    private var captureRail: some View {
        VStack(spacing: 14) {
            ForEach(captureActionIDs, id: \.self) { actionID in
                context.nodeView(of: actionID)
                    .frame(width: 44, height: 44)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
        .modifier(LGLiquidGlassSurface(shape: .capsule))
        .fixedSize()
    }


    private func searchSurface(_ base: AnyView, active: Bool) -> some View {
        ZStack {
            base
                .allowsHitTesting(!searchVisible)
                .accessibilityHidden(searchVisible)
            if active, let search, search.isVisible {
                if search.context.childIDs.indices.contains(1) {
                    let background = routeBackground
                    search.context.content(for: search.context.childIDs[1])
                        .environment(\.luiTextHighlightQuery, search.query)
                        .environment(\.defaultMinListRowHeight, 0)
                        .transformEnvironment(\.luiSemanticColors) { colors in
                            colors["background"] = background
                            colors["surface"] = background
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(background)
                        // A principal text item creates a horizontal title bar
                        // alongside Duo's vertical controls. Keep the status in
                        // the search surface so dismissing it cannot reflow home.
                        .safeAreaInset(edge: .top, spacing: 0) {
                            if verticalToolbar {
                                Text(search.statusTitle)
                                    .font(.headline)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(background)
                                    .accessibilityIdentifier("search.status")
                            }
                        }
                        .opacity(search.resultsAreVisible ? 1 : 0)
                        .accessibilityHidden(!search.resultsAreVisible)
                        .animation(nil, value: search.resultsAreVisible)
                        .transition(.identity)
                }
            }
        }
    }

    @ViewBuilder
    private func destinationSurface(_ childID: Int) -> some View {
        if let search, searchRoutes.contains(childID) {
            withAppTint(search.context.content(for: childID))
                .onAppear { search.suspendInput() }
        } else {
            withAppTint(searchSurface(context.content(for: childID), active: childID == path.last))
        }
    }

    @ViewBuilder
    private func withAppTint<Content: View>(_ content: Content) -> some View {
        #if os(iOS)
        content.tint(LogseqThemePolicy.accent)
        #else
        content
        #endif
    }

    #if os(iOS)
    private var navigationBarTint: Color? {
        // The system picks the contrast of its Liquid Glass back control.
        if #available(iOS 26.0, *) { return nil }
        return themePalette.primaryText
    }
    #endif

    private var themePalette: LogseqThemePalette {
        LogseqThemePolicy.palette(
            mode: LogseqThemeMode(rawValue: appearance) ?? .system,
            systemIsDark: colorScheme == .dark,
            darkTheme: darkTheme
        )
    }

    private var routeBackground: Color {
        #if os(iOS)
        if LGNavigationSurfacePolicy.usesSystemGroupedBackground(
            contentPreference: usesSystemGroupedBackground
        ) {
            return Color(uiColor: .systemGroupedBackground)
        }
        #endif
        return themePalette.background
    }

    private var navigationTitle: String {
        guard case let .string(value) = context.property("title") else { return "" }
        return value
    }

    private var contextualTitle: String {
        navigationTitle.isEmpty ? visibleScrollTitle ?? "" : navigationTitle
    }

    private var navigationContentTopPadding: CGFloat {
        0
    }

    private var destinationContentTopPadding: CGFloat {
        0
    }

    @ToolbarContentBuilder
    private func trailingToolbar(searchPage: Bool) -> some ToolbarContent {
        if let toolbarStartIndex {
            if #available(iOS 26.0, *) {
                ToolbarItem(id: "logseq.trailing-controls", placement: trailingToolbarPlacement) {
                    trailingControls(searchPage: searchPage, index: toolbarStartIndex, glass: true)
                }
                .sharedBackgroundVisibility(.hidden)
                .lgPrefersVerticalAxis()
            } else {
                ToolbarItem(id: "logseq.trailing-controls", placement: trailingToolbarPlacement) {
                    trailingControls(searchPage: searchPage, index: toolbarStartIndex, glass: false)
                }
            }
        } else if let item = trailingToolbarItem(searchPage: searchPage) {
            ToolbarItem(id: item.id, placement: trailingToolbarPlacement) {
                item.content
                    .overlay {
                        if composerDismissalEnabled {
                            composerDismissalTarget.accessibilityHidden(true)
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
            }
            .lgPrefersVerticalAxis()
        }
    }

    @ViewBuilder
    private func trailingControls(searchPage: Bool, index: Int, glass: Bool) -> some View {
        if !searchPage && hasPrimaryToolbarAction(at: index) {
            pairedTrailingControls(index: index, glass: glass)
        } else {
            let action = Group {
                if selectionActive {
                    headerConnectionSlot(context, at: childID(at: index + 3), selecting: true)
                } else if let item = trailingToolbarItem(searchPage: searchPage) {
                    item.content
                }
            }
            .frame(width: 44, height: 44)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .overlay {
                if composerDismissalEnabled { composerDismissalTarget.accessibilityHidden(true) }
            }
            if glass {
                action.modifier(LGLiquidGlassSurface(shape: .circle))
            } else {
                action
            }
        }
    }

    private func pairedTrailingControls(index: Int, glass: Bool) -> some View {
        let size: CGFloat = 44
        let fullWidth = verticalToolbar ? size : size * 2
        let fullHeight = verticalToolbar ? size * 2 : size
        let alignment: Alignment = verticalToolbar ? .top : .trailing
        let contents = ZStack(alignment: alignment) {
            if selectionActive {
                headerConnectionSlot(context, at: childID(at: index + 3), selecting: true)
                    .frame(width: size, height: size)
                    .transition(.opacity)
            } else if let item = trailingToolbarItem(searchPage: false) {
                item.content
                    .transition(.opacity)
            }
        }
        .frame(width: selectionActive ? size : fullWidth,
               height: selectionActive ? size : fullHeight, alignment: alignment)
        .clipShape(Capsule())
        return trailingChrome(contents, glass: glass)
            // The system toolbar keeps one footprint while its glass resizes in place.
            .frame(width: fullWidth, height: fullHeight, alignment: alignment)
            .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: selectionActive)
            .overlay {
                if composerDismissalEnabled { composerDismissalTarget.accessibilityHidden(true) }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
    }

    @ViewBuilder
    private func trailingChrome<Content: View>(_ content: Content, glass: Bool) -> some View {
        if #available(iOS 26.0, macOS 26.0, *), glass {
            GlassEffectContainer(spacing: 0) {
                content.glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("navigation-actions", in: trailingGlass)
            }
        } else { content }
    }

    private func headerConnectionSlot(
        _ owner: LUIAppleExtensionViewContext, at container: Int?, selecting: Bool
    ) -> AnyView {
        guard let container else { return AnyView(EmptyView()) }
        let _ = owner.measureStamp(of: container)
        let slots = owner.childIDs(of: container)
        let index = selecting ? 1 : 0
        guard slots.indices.contains(index) else { return AnyView(EmptyView()) }
        return owner.nodeView(of: slots[index])
    }

    private func hasPrimaryToolbarAction(at index: Int) -> Bool {
        guard let container = childID(at: index + 2) else { return false }
        let _ = context.measureStamp(of: container)
        return !context.childIDs(of: container).isEmpty
    }

    private func trailingToolbarItem(searchPage: Bool) -> (id: String, content: AnyView)? {
        let pageActions: AnyView
        if searchPage, let search, search.context.childIDs.indices.contains(3) {
            pageActions = headerConnectionSlot(search.context, at: search.context.childIDs[3], selecting: false)
        } else if let toolbarStartIndex {
            pageActions = headerConnectionSlot(context, at: childID(at: toolbarStartIndex + 3), selecting: false)
            if hasPrimaryToolbarAction(at: toolbarStartIndex) {
                // Keep the two actions together so the system gives them a single toolbar slot.
                let controls = LGToolbarControlPair(
                    first: AnyView(childContent(at: toolbarStartIndex + 2).frame(width: 44, height: 44)),
                    second: AnyView(pageActions.frame(width: 44, height: 44))
                )
                .fixedSize()
                return ("logseq.trailing-controls", AnyView(controls))
            }
        } else if let trailingMenuIndex {
            pageActions = childContent(at: trailingMenuIndex)
        } else {
            return nil
        }
        return (
            "logseq.search.page-actions",
            AnyView(pageActions.frame(width: 44, height: 44))
        )
    }

    private var bottomChrome: AnyView {
        if showsSearchPage, let search, search.context.childIDs.indices.contains(2) {
            return search.context.content(for: search.context.childIDs[2])
        }
        guard let bottomChromeIndex else { return AnyView(EmptyView()) }
        return childContent(at: bottomChromeIndex)
    }

    @ViewBuilder
    private var floatingBottomChrome: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 0) { sizedBottomChrome }
            } else {
                sizedBottomChrome
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var sizedBottomChrome: some View {
        if bottomOccupiesLayoutSpace {
            withAppTint(bottomChrome)
                .fixedSize(horizontal: false, vertical: true)
                #if os(iOS)
                .background(OutlinerEditorToolbarGuide())
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    outlinerToolbarReserve.chromeHeight = height
                }
                .onDisappear { outlinerToolbarReserve.chromeHeight = 0 }
                #endif
                .modifier(LGBottomChromeSurface())
                .modifier(LGBottomChromeHitTarget(isRounded: true))
                .padding(.horizontal, 16)
                .padding(.bottom, LGNavigationSurfacePolicy.bottomPadding(
                    occupiesLayoutSpace: true
                ))
        } else {
            withAppTint(bottomChrome)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(LGBottomChromeHitTarget(isRounded: false))
        }
    }

    private var desiredPath: [Int] {
        pageRoutes(in: context, depth: depth) + searchRoutes
    }

    private func pageRoutes(in context: LUIAppleExtensionViewContext, depth: Int) -> [Int] {
        // Depth can arrive before the destination child. The adjacent capture
        // controls and file preview must never enter the native stack.
        Array(context.childIDs.lazy.filter {
            context.extensionIdentifier(of: $0) == LGNavigationExtension.destinationIdentifier
        }.prefix(max(0, depth)))
    }

    private var trailingToolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }

    private var rootLeadingToolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    private var pathBinding: Binding<[Int]> {
        Binding(
            get: { path },
            set: { newPath in
                LGInteractionDiagnostics.event("navigation.binding", "node=\(context.nodeID) path=\(path) new=\(newPath) desired=\(desiredPath)")
                let removedCount = max(0, path.count - newPath.count)
                if removedCount > 0 {
                    if composerDismissalEnabled { emitDismissComposer() }
                    nativePop = LGNativeNavigationPop(original: nativePop?.original ?? desiredPath, target: newPath)
                    #if os(iOS)
                    // Keep the outgoing route alive until UIKit finishes its pop.
                    transitions.afterPop { emitBack(count: removedCount) }
                    #else
                    emitBack(count: removedCount)
                    #endif
                }
            }
        )
    }

    private func emitBack(count: Int) {
        do {
            try (showsSearchPage ? search!.context : context).emit(name: "back", values: ["count": .int(count)])
        } catch {
            logger.error(
                "Could not synchronize native \(synchronizationName): \(String(describing: error))"
            )
        }
    }

    private func dismissComposerFromTap() {
        #if os(iOS)
        // Resign before the core drops the field so the keyboard slides away
        // instead of vanishing with it.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        emitDismissComposer()
    }

    private func emitDismissComposer() {
        do {
            try context.emit(name: "dismiss-composer", values: [:])
        } catch {
            logger.error("Could not dismiss composer: \(String(describing: error))")
        }
    }
}

#if os(iOS)
@available(iOS 26.0, *)
@MainActor
private struct LGNativeSearchControllerBridge: UIViewControllerRepresentable {
    let search: LGNativeSearchState

    func makeUIViewController(context: Context) -> Observer { Observer(search: search) }
    func updateUIViewController(_ controller: Observer, context: Context) { controller.synchronize() }
    static func dismantleUIViewController(_ controller: Observer, coordinator: ()) { controller.detach() }

    final class Observer: UIViewController, UISearchControllerDelegate, UISearchResultsUpdating {
        let state: LGNativeSearchState
        let controller = UISearchController(searchResultsController: nil)
        weak var host: UIViewController?
        private var needsInitialFocus = false

        init(search: LGNativeSearchState) {
            state = search
            super.init(nibName: nil, bundle: nil)
            controller.delegate = self
            controller.searchResultsUpdater = self
            controller.obscuresBackgroundDuringPresentation = false
            // Search lives in the bottom toolbar. Collapsing the top bar changes
            // the safe area and adds a second transition when returning from a result.
            controller.hidesNavigationBarDuringPresentation = false
            controller.searchBar.searchTextField.accessibilityIdentifier = "field.native-search"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func loadView() { view = UIView() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); synchronize() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); synchronize() }

        func synchronize() {
            if host == nil {
                var ancestor = parent
                while let candidate = ancestor {
                    if candidate.parent is UINavigationController { host = candidate; break }
                    ancestor = candidate.parent
                }
            }
            guard let host, let navigation = host.navigationController else { return }
            if state.nativePresented, navigation.topViewController === host, view.window != nil {
                host.definesPresentationContext = true
                controller.searchBar.placeholder = state.title
                let text = state.queryBinding.wrappedValue
                if controller.searchBar.text != text { controller.searchBar.text = text }
                if host.navigationItem.searchController !== controller {
                    host.navigationItem.searchController = controller
                    host.navigationItem.preferredSearchBarPlacement = .integratedButton
                    host.navigationItem.searchBarPlacementAllowsToolbarIntegration = true
                    let appearance = UIToolbarAppearance()
                    appearance.configureWithTransparentBackground()
                    navigation.toolbar.standardAppearance = appearance
                    navigation.toolbar.scrollEdgeAppearance = appearance
                }
                let item = host.navigationItem.searchBarPlacementBarButtonItem
                if !(host.toolbarItems ?? []).contains(where: { $0 === item }) { host.toolbarItems = [item] }
                if navigation.isToolbarHidden { navigation.setToolbarHidden(false, animated: false) }
                if !controller.isActive {
                    needsInitialFocus = true
                    // Let editing activate the integrated search bar so UIKit can
                    // coordinate its expansion with the keyboard in one transition.
                    focusIfNeeded()
                    if !controller.isActive { controller.isActive = true }
                }
            } else if !state.nativePresented, controller.isActive {
                controller.isActive = false
            } else if !state.isVisible, !controller.isActive {
                detach()
            }
        }

        func detach() {
            guard let host, host.navigationItem.searchController === controller else { return }
            let item = host.navigationItem.searchBarPlacementBarButtonItem
            host.toolbarItems = host.toolbarItems?.filter { $0 !== item }
            if (host.toolbarItems ?? []).isEmpty { host.navigationController?.setToolbarHidden(true, animated: false) }
            host.navigationItem.searchController = nil
        }

        private func focusIfNeeded() {
            guard state.nativePresented, needsInitialFocus else { return }
            if controller.searchBar.searchTextField.becomeFirstResponder() { needsInitialFocus = false }
        }

        func willPresentSearchController(_ searchController: UISearchController) {
            LogseqCrashReporting.uiState(nativeSearchActive: true)
        }
        func didPresentSearchController(_ searchController: UISearchController) {
            DispatchQueue.main.async { [weak self] in self?.focusIfNeeded() }
        }
        func willDismissSearchController(_ searchController: UISearchController) {
            LogseqCrashReporting.uiState(nativeSearchActive: false)
            needsInitialFocus = false
            state.nativeWillDismiss()
        }
        func didDismissSearchController(_ searchController: UISearchController) {
            detach()
            state.finishDismissal()
        }
        func updateSearchResults(for searchController: UISearchController) {
            let text = searchController.searchBar.text ?? ""
            if text != state.queryBinding.wrappedValue { state.queryBinding.wrappedValue = text }
        }
    }
}

@MainActor
private final class LGNavigationTransitions {
    weak var controller: UINavigationController?

    func afterSearchDismissal(_ completion: @escaping @MainActor () -> Void) {
        let search = controller?.topViewController?.navigationItem.searchController
        Task { @MainActor in
            if let coordinator = search?.transitionCoordinator,
               coordinator.animate(alongsideTransition: nil, completion: { _ in completion() }) {
                return
            }
            completion()
        }
    }

    func afterPop(_ completion: @escaping @MainActor () -> Void) {
        guard let coordinator = controller?.transitionCoordinator else {
            completion()
            return
        }
        _ = coordinator.animate(alongsideTransition: nil) { context in
            if !context.isCancelled { completion() }
        }
    }
}

@MainActor
private struct LGNavigationControllerObserver: UIViewControllerRepresentable {
    let transitions: LGNavigationTransitions

    func makeUIViewController(context: Context) -> Observer {
        Observer(transitions: transitions)
    }

    func updateUIViewController(_ controller: Observer, context: Context) {
        controller.resolveNavigationController()
    }

    final class Observer: UIViewController {
        let transitions: LGNavigationTransitions

        init(transitions: LGNavigationTransitions) {
            self.transitions = transitions
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func loadView() { view = UIView() }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            resolveNavigationController()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            resolveNavigationController()
        }

        func resolveNavigationController() {
            if let navigationController { transitions.controller = navigationController }
        }
    }
}
#endif

private struct LGBottomChromeSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 28))
        } else {
            content.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
        }
    }
}

// Keep the chrome boundary without an ancestor recognizer that can consume
// touches intended for native menus or the composer's independent focus buttons.
private struct LGBottomChromeHitTarget: ViewModifier {
    let isRounded: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isRounded {
            content
                .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        } else {
            content
                .contentShape(Rectangle())
        }
    }
}
