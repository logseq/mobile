import LUIAppleBackend
import SwiftUI
#if os(iOS)
import UIKit
#endif

enum LGNavigationSurfacePolicy {
    static let androidContentTopPadding = CGFloat(0)
    static let androidDestinationContentTopPadding = CGFloat(56)

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

    static func sidebarGraphWidth(_ availableWidth: CGFloat) -> CGFloat {
        // Keep room for Settings, the system sidebar toggle, and toolbar margins.
        max(44, availableWidth - 2 * 44 - 3 * 16)
    }
}

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
            // Observe the root view's docked guide; the rendered content may already
            // have been resized by SwiftUI's floating-keyboard avoidance.
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

@MainActor
enum LGNavigationExtension {
    static let identifier = "native-navigation-stack"
    static let fingerprint = "lui-extension-v1|23:native-navigation-stack|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:10:back-depth:int:required:none,26:composer-dismissal-enabled:bool:required:none,28:bottom-occupies-layout-space:bool:required:none,5:depth:int:required:none,5:title:string:required:none|events:16:dismiss-composer[],16:viewport-changed[5:width:int:required],4:back[5:count:int:required]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.registerTweak(
            LUIAppleTweak(
                identifier: "native-control-tint",
                fingerprint: "lui-tweak-v1|19:native-control-tint|profiles:ios/swiftui|properties:4:role:string:required:none",
                properties: [.init(name: "role", kind: .string, isRequired: true)]
            ) { content, context in
                if case .string("switch") = context.property("role") {
                    return AnyView(content.toggleStyle(SwitchToggleStyle(tint: LogseqThemePolicy.accent))
                        .tint(LogseqThemePolicy.accent))
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
                identifier: identifier,
                fingerprint: fingerprint,
                acceptsStandardChildren: true,
                properties: [
                    .init(name: "back-depth", kind: .int, isRequired: true),
                    .init(name: "depth", kind: .int, isRequired: true),
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
                identifier: "native-navigation-title",
                fingerprint: "lui-tweak-v1|23:native-navigation-title|profiles:ios/swiftui|properties:5:title:string:required:none",
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
        .background(LGNotificationSafeAreaReader { topInset = $0 })
        #else
        .onAppear { topInset = 0 }
        #endif
    }
}

#if os(iOS)
private struct LGNotificationSafeAreaReader: UIViewRepresentable {
    let update: (CGFloat) -> Void

    func makeUIView(context: Context) -> Probe { Probe(update: update) }
    func updateUIView(_ view: Probe, context: Context) { view.measure() }

    final class Probe: UIView {
        let update: (CGFloat) -> Void
        private var reported: CGFloat?
        init(update: @escaping (CGFloat) -> Void) {
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
            // The drawer fills the window, so SwiftUI's inherited safe area is empty.
            let inset = max(0, window.safeAreaInsets.top - convert(CGPoint.zero, to: window).y)
            guard inset != reported else { return }
            reported = inset
            DispatchQueue.main.async { [update] in update(inset) }
        }
    }
}
#endif

private struct LGSidebarNavigation: View {
    let context: LUIAppleExtensionViewContext
    @AppStorage("logseq.appearance") private var appearance = "system"
    @Environment(\.colorScheme) private var colorScheme

    private var background: Color {
        LogseqThemePolicy.palette(mode: LogseqThemeMode(rawValue: appearance) ?? .system,
                                  systemIsDark: colorScheme == .dark).background
    }

    var body: some View {
        let _ = context.revision
        GeometryReader { geometry in
            NavigationStack {
                child(at: 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(background.ignoresSafeArea())
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(background, for: .navigationBar)
                    #endif
                    .toolbar {
                        #if os(iOS)
                        if #available(iOS 26.0, *) {
                            ToolbarItem(placement: .topBarLeading) {
                                child(at: 1)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(width: LGNavigationSurfacePolicy.sidebarGraphWidth(geometry.size.width), alignment: .leading)
                            }
                            .sharedBackgroundVisibility(.hidden)
                            ToolbarItem(placement: .topBarTrailing) { child(at: 2) }
                                .sharedBackgroundVisibility(.hidden)
                        } else {
                            ToolbarItem(placement: .topBarLeading) {
                                child(at: 1).lineLimit(1).truncationMode(.middle)
                                    .frame(width: LGNavigationSurfacePolicy.sidebarGraphWidth(geometry.size.width), alignment: .leading)
                            }
                            ToolbarItem(placement: .topBarTrailing) { child(at: 2) }
                        }
                        #else
                        ToolbarItem(placement: .navigation) { child(at: 1) }
                        ToolbarItem(placement: .primaryAction) { child(at: 2) }
                        #endif
                    }
            }
        }
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
            routeStartIndex: 6,
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
    static let fingerprint = "lui-extension-v1|26:native-search-presentation|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:10:back-title:string:optional:none,11:clear-title:string:optional:none,11:close-title:string:optional:none,28:bottom-occupies-layout-space:bool:required:none,5:depth:int:required:none,5:query:string:required:none,5:title:string:required:none,9:presented:bool:required:none|events:13:query-changed[5:query:string:required],4:back[5:count:int:required],7:dismiss[]"

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
                    .init(name: "title", kind: .string, isRequired: true),
                ],
                events: [
                    .init(name: "back", fields: [
                        .init(name: "count", kind: .int, isRequired: true),
                    ]),
                    .init(name: "dismiss", fields: []),
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
private struct LGSearchPresentation: View {
    let context: LUIAppleExtensionViewContext
    @State private var nativePresented = false

    var body: some View {
        ZStack {
            baseContent
                .ignoresSafeArea(.keyboard, edges: nativePresented ? .bottom : [])
                .allowsHitTesting(!nativePresented)
                .accessibilityHidden(nativePresented)
            if nativePresented {
                LGSearchSession(context: context, close: closeSearch)
                    .zIndex(1)
            }
        }
        .onChange(of: presented, initial: true) {
            if presented {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { nativePresented = true }
            } else {
                closeSearch()
            }
        }
    }

    private var baseContent: AnyView {
        guard let childID = context.childIDs.first else { return AnyView(EmptyView()) }
        return context.content(for: childID)
    }

    private var presented: Bool {
        guard case let .bool(value) = context.property("presented") else { return false }
        return value
    }

    private func closeSearch() {
        guard nativePresented else { return }
        // The system search control already animates cancellation and the keyboard.
        // Retire this layer without adding another presentation transition.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { nativePresented = false }
        didDismiss()
    }

    private func didDismiss() {
        if presented { try? context.emit(name: "dismiss", values: [:]) }
    }
}

private struct LGSearchSession: View {
    let context: LUIAppleExtensionViewContext
    let close: () -> Void
    @State private var pendingQuery: String?
    #if os(iOS)
    @State private var nativeSearchPresented = true
    @State private var closing = false
    #endif

    var body: some View {
        searchNavigation
            .onChange(of: query) {
                if pendingQuery == query { pendingQuery = nil }
            }
            #if os(iOS)
            .task(id: closing) {
                // Finish the native cancel callback before retiring this layer,
                // without waiting for the keyboard's dismissal animation.
                if closing { close() }
            }
            .onChange(of: depth) {
                if depth == 0 && !closing { nativeSearchPresented = true }
            }
            #endif
    }

    private var searchNavigation: some View {
        LGNavigationContent(
            context: context,
            rootIndex: 1,
            routeStartIndex: 4,
            synchronizationName: "search navigation",
            toolbarStartIndex: nil,
            trailingMenuIndex: 3,
            bottomChromeIndex: 2,
            rootTransform: searchRootTransform
        )
    }

    private func searchRootTransform(_ content: AnyView) -> AnyView {
        let content = AnyView(content.environment(\.luiTextHighlightQuery, query))
        #if os(iOS)
        let observedContent = AnyView(content.background(LGSearchDismissalObserver(
            willDismiss: { if depth == 0 { exitSearch() } }
        )))
        if #available(iOS 26.0, *) {
            return AnyView(nativeBottomSearch(observedContent))
        }
        return AnyView(nativeLegacySearch(observedContent))
        #else
        return AnyView(nativeAutomaticSearch(content))
        #endif
    }

    private func nativeAutomaticSearch(_ content: AnyView) -> some View {
        content
            .searchable(
                text: queryBinding,
                placement: .automatic,
                prompt: Text(searchTitle)
            )
    }

    #if os(iOS)
    private func nativeLegacySearch(_ content: AnyView) -> some View {
        content
            .navigationTitle(searchTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: queryBinding,
                isPresented: nativeSearchPresentedBinding,
                placement: .automatic,
                prompt: Text(searchTitle)
            )
            .onAppear {
                nativeSearchPresented = true
            }
    }

    @available(iOS 26.0, *)
    private func nativeBottomSearch(_ content: AnyView) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: queryBinding,
                isPresented: nativeSearchPresentedBinding,
                placement: .toolbar,
                prompt: Text(searchTitle)
            )
            .toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            }
            .toolbar(depth == 0 ? .hidden : .visible, for: .navigationBar)
    }

    private func exitSearch() {
        guard !closing else { return }
        closing = true
        pendingQuery = query
    }

    private var nativeSearchPresentedBinding: Binding<Bool> {
        Binding(
            get: { nativeSearchPresented },
            set: { isPresented in
                nativeSearchPresented = isPresented
                if !isPresented && depth == 0 { exitSearch() }
            }
        )
    }
    #endif

    private var depth: Int {
        guard case let .int(value) = context.property("depth") else { return 0 }
        return value
    }

    private var query: String {
        guard case let .string(value) = context.property("query") else { return "" }
        return value
    }

    private var searchTitle: String {
        guard case let .string(value) = context.property("title") else { return "Search" }
        return value
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { pendingQuery ?? query },
            set: { newValue in
                #if os(iOS)
                guard !closing else { return }
                #endif
                // Keep local typing ahead of asynchronous core acknowledgements.
                pendingQuery = newValue
                // Native Cancel also clears its text binding. Let the presentation
                // binding close first so that event cannot clear the outgoing results.
                Task { @MainActor in
                    #if os(iOS)
                    guard !closing, nativeSearchPresented else { return }
                    #endif
                    guard pendingQuery == newValue else { return }
                    emitQueryChanged(newValue)
                }
            }
        )
    }

    private func emitQueryChanged(_ query: String) {
        do {
            try context.emit(name: "query-changed", values: ["query": .string(query)])
        } catch {
            logger.error("Could not update native search query: \(String(describing: error))")
        }
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
    let routeStartIndex: Int
    let synchronizationName: String
    let toolbarStartIndex: Int?
    let trailingMenuIndex: Int?
    let bottomChromeIndex: Int?
    let rootTransform: ((AnyView) -> AnyView)?
    @State private var nativePop: LGNativeNavigationPop?
    #if os(iOS)
    @State private var transitions = LGNavigationTransitions()
    @State private var dockedKeyboardInset: CGFloat = 0
    #endif
    @State private var usesSystemGroupedBackground = false
    @State private var visibleScrollTitle: String?
    @AppStorage("logseq.appearance") private var appearance = "system"
    @Environment(\.colorScheme) private var colorScheme

    // This view observes the extension independently of its parent. Read the
    // route depth and chrome from the same live model as the child IDs.
    private var depth: Int {
        guard case let .int(value) = context.property("depth") else { return 0 }
        return value
    }

    private var bottomOccupiesLayoutSpace: Bool {
        guard case let .bool(value) = context.property("bottom-occupies-layout-space") else { return false }
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
        navigationLayout
            .onPreferenceChange(LUIListSurfacePreferenceKey.self) { usesSystemBackground in
                usesSystemGroupedBackground = usesSystemBackground
            }
            .onPreferenceChange(LUIScrollTitlePreferenceKey.self) { title in
                visibleScrollTitle = title
            }
    }

    @ViewBuilder
    private var navigationLayout: some View {
        navigationStack
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if bottomOccupiesLayoutSpace {
                    sizedBottomChrome
                }
            }
            .overlay(alignment: .bottom) {
                if !bottomOccupiesLayoutSpace {
                    sizedBottomChrome
                }
            }
            #if os(iOS)
            .padding(.bottom, dockedKeyboardInset)
            .ignoresSafeArea(.keyboard, edges: UIDevice.current.userInterfaceIdiom == .pad ? .bottom : [])
            .background {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    LGDockedKeyboardInsetReader { dockedKeyboardInset = $0 }
                }
            }
            #endif
            .background(routeBackground.ignoresSafeArea())
    }

    private var navigationStack: some View {
        let title = toolbarStartIndex == nil ? "" : (navigationTitle.isEmpty ? visibleScrollTitle ?? "" : navigationTitle)
        return NavigationStack(path: pathBinding) {
            Group {
                if toolbarStartIndex != nil { rootNavigationSurface.navigationTitle(title) }
                else { rootNavigationSurface }
            }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .background(routeBackground)
                .overlay {
                    if composerDismissalEnabled {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: emitDismissComposer)
                            .accessibilityLabel("Dismiss composer")
                            .accessibilityIdentifier("surface.composer.dismiss")
                    }
                }
                .navigationDestination(for: Int.self) { childID in
                    context.content(for: childID)
                        .padding(.top, destinationContentTopPadding)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .background(routeBackground)
                        .toolbar {
                            trailingToolbar
                        }
                }
                .toolbar {
                    if let toolbarStartIndex,
                       let leadingID = childID(at: toolbarStartIndex) {
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
                        } else {
                            ToolbarItem(placement: rootLeadingToolbarPlacement) {
                                context.content(for: leadingID)
                            }
                        }
                        trailingToolbar
                    }
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                #endif
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(routeBackground.ignoresSafeArea())
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(routeBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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

    @ViewBuilder
    private var rootNavigationSurface: some View {
        transformedRootContent
            .padding(.top, navigationContentTopPadding)
            #if os(iOS)
            .background(LGNavigationControllerObserver(transitions: transitions).allowsHitTesting(false))
            #endif
    }


    private var themePalette: LogseqThemePalette {
        LogseqThemePolicy.palette(
            mode: LogseqThemeMode(rawValue: appearance) ?? .system,
            systemIsDark: colorScheme == .dark
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

    private var navigationContentTopPadding: CGFloat {
        0
    }

    private var destinationContentTopPadding: CGFloat {
        0
    }

    @ToolbarContentBuilder
    private var trailingToolbar: some ToolbarContent {
        if let toolbarStartIndex {
            ToolbarItem(id: "logseq.trailing-controls", placement: trailingToolbarPlacement) {
                // Keep these controls in one item so the system cannot replace
                // one of them with its own overflow menu as the title changes.
                HStack(spacing: 0) {
                    childContent(at: toolbarStartIndex + 2)
                        .frame(width: 44, height: 44)
                    childContent(at: toolbarStartIndex + 3)
                        .frame(width: 44, height: 44)
                }
                .fixedSize()
                .menuStyle(.button)
                .buttonStyle(.plain)
            }
        } else if let trailingMenuIndex {
            ToolbarItem(id: "logseq.search.page-actions", placement: trailingToolbarPlacement) {
                childContent(at: trailingMenuIndex)
                    .frame(width: 44, height: 44)
                    .menuStyle(.button)
                    .buttonStyle(.plain)
            }
        }
    }

    private var bottomChrome: AnyView {
        guard let bottomChromeIndex else { return AnyView(EmptyView()) }
        return childContent(at: bottomChromeIndex)
    }

    @ViewBuilder
    private var sizedBottomChrome: some View {
        if bottomOccupiesLayoutSpace {
            bottomChrome
                .fixedSize(horizontal: false, vertical: true)
                .modifier(LGBottomChromeSurface())
                .modifier(LGBottomChromeHitTarget(isRounded: true))
                .padding(.horizontal, 16)
                .padding(.bottom, LGNavigationSurfacePolicy.bottomPadding(
                    occupiesLayoutSpace: true
                ))
        } else {
            bottomChrome
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(LGBottomChromeHitTarget(isRounded: false))
        }
    }

    private var desiredPath: [Int] {
        let childIDs = context.childIDs
        let availableDepth = max(0, childIDs.count - routeStartIndex)
        let retainedDepth = min(max(0, depth), availableDepth)
        var result: [Int] = []
        for index in 0..<retainedDepth {
            result.append(childIDs[index + routeStartIndex])
        }
        return result
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
            try context.emit(name: "back", values: ["count": .int(count)])
        } catch {
            logger.error(
                "Could not synchronize native \(synchronizationName): \(String(describing: error))"
            )
        }
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
@MainActor
private struct LGSearchDismissalObserver: UIViewControllerRepresentable {
    let willDismiss: () -> Void

    func makeUIViewController(context: Context) -> Observer {
        Observer(willDismiss: willDismiss)
    }

    func updateUIViewController(_ controller: Observer, context: Context) {
        controller.proxy.willDismiss = willDismiss
        controller.resolve()
    }

    static func dismantleUIViewController(_ controller: Observer, coordinator: ()) {
        controller.uninstall()
    }

    final class Observer: UIViewController {
        let proxy: Delegate
        weak var search: UISearchController?

        init(willDismiss: @escaping () -> Void) {
            proxy = Delegate(willDismiss: willDismiss)
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func loadView() { view = UIView() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); resolve() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); resolve() }

        func resolve() {
            guard let search = navigationController?.viewControllers.compactMap({ $0.navigationItem.searchController }).first,
                  search.delegate !== proxy else { return }
            uninstall()
            self.search = search
            proxy.forwarded = search.delegate
            search.delegate = proxy
        }

        func uninstall() {
            if let search, search.delegate === proxy { search.delegate = proxy.forwarded }
            search = nil
        }
    }

    final class Delegate: NSObject, UISearchControllerDelegate {
        // UIKit's optional-method lookup is nonisolated; installation stays on the main actor.
        nonisolated(unsafe) weak var forwarded: UISearchControllerDelegate?
        var willDismiss: () -> Void

        init(willDismiss: @escaping () -> Void) {
            self.willDismiss = willDismiss
        }

        func willDismissSearchController(_ searchController: UISearchController) {
            willDismiss()
            forwarded?.willDismissSearchController?(searchController)
        }

        nonisolated override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || forwarded?.responds(to: selector) == true
        }

        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            if let forwarded, forwarded.responds(to: selector) { return forwarded }
            return super.forwardingTarget(for: selector)
        }
    }
}

@MainActor
private final class LGNavigationTransitions {
    weak var controller: UINavigationController?

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
