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
}

@MainActor
enum LGNavigationExtension {
    static let identifier = "native-navigation-stack"
    static let fingerprint = "lui-extension-v1|23:native-navigation-stack|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:10:back-depth:int:required:none,26:composer-dismissal-enabled:bool:required:none,28:bottom-occupies-layout-space:bool:required:none,5:depth:int:required:none,5:title:string:required:none|events:16:dismiss-composer[],4:back[5:count:int:required]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
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

private struct LGSidebarNavigation: View {
    let context: LUIAppleExtensionViewContext

    var body: some View {
        let _ = context.revision
        NavigationStack {
            child(at: 0)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    #if os(iOS)
                    if #available(iOS 26.0, *) {
                        ToolbarItem(placement: .topBarLeading) {
                            child(at: 1).fixedSize(horizontal: true, vertical: false)
                        }
                        .sharedBackgroundVisibility(.hidden)
                        ToolbarItem(placement: .topBarTrailing) { child(at: 2) }
                            .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .topBarLeading) { child(at: 1) }
                        ToolbarItem(placement: .topBarTrailing) { child(at: 2) }
                    }
                    #else
                    ToolbarItem(placement: .navigation) { child(at: 1) }
                    ToolbarItem(placement: .primaryAction) { child(at: 2) }
                    #endif
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
            depth: depth,
            synchronizationName: "navigation",
            toolbarStartIndex: 1,
            bottomChromeIndex: 5,
            bottomOccupiesLayoutSpace: bottomOccupiesLayoutSpace,
            composerDismissalEnabled: composerDismissalEnabled,
            rootTransform: nil
        )
    }

    private var depth: Int {
        guard case let .int(value) = context.property("depth") else { return 0 }
        return value
    }

    private var bottomOccupiesLayoutSpace: Bool {
        guard case let .bool(value) = context.property("bottom-occupies-layout-space") else {
            return false
        }
        return value
    }

    private var composerDismissalEnabled: Bool {
        guard case let .bool(value) = context.property("composer-dismissal-enabled") else {
            return false
        }
        return value
    }

}

private struct LGNavigationDestination: View {
    let context: LUIAppleExtensionViewContext
    let content: AnyView

    var body: some View {
        let _ = context.revision
        content
            .navigationTitle(title)
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
    static let fingerprint = "lui-extension-v1|26:native-search-presentation|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:5:depth:int:required:none,5:query:string:required:none,5:title:string:required:none,9:presented:bool:required:none|events:13:query-changed[5:query:string:required],4:back[5:count:int:required],7:dismiss[]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(
            LUIAppleExtension(
                identifier: identifier,
                fingerprint: fingerprint,
                acceptsStandardChildren: true,
                properties: [
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

    var body: some View {
        baseContent
            .fullScreenCover(isPresented: presentedBinding) {
                LGSearchSession(context: context)
                    .presentationBackground(.background)
            }
            .transaction(value: presented) { $0.disablesAnimations = true }
    }

    private var baseContent: AnyView {
        guard let childID = context.childIDs.first else { return AnyView(EmptyView()) }
        return context.content(for: childID)
    }

    private var presented: Bool {
        guard case let .bool(value) = context.property("presented") else { return false }
        return value
    }

    private var presentedBinding: Binding<Bool> {
        Binding(get: { presented }, set: { value in
            if !value { try? context.emit(name: "dismiss", values: [:]) }
        })
    }
}

private struct LGSearchSession: View {
    let context: LUIAppleExtensionViewContext
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
            .onChange(of: depth) {
                if depth == 0 && !closing { nativeSearchPresented = true }
            }
            #endif
    }

    private var searchNavigation: some View {
        LGNavigationContent(
            context: context,
            rootIndex: 1,
            routeStartIndex: 2,
            depth: depth,
            synchronizationName: "search navigation",
            toolbarStartIndex: nil,
            bottomChromeIndex: nil,
            bottomOccupiesLayoutSpace: false,
            composerDismissalEnabled: false,
            rootTransform: searchRootTransform
        )
    }

    private func searchRootTransform(_ content: AnyView) -> AnyView {
        let content = AnyView(content.environment(\.luiTextHighlightQuery, query))
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return AnyView(nativeBottomSearch(content))
        }
        return AnyView(nativeLegacySearch(content))
        #else
        return AnyView(nativeAutomaticSearch(content))
        #endif
    }

    private func nativeAutomaticSearch(_ content: AnyView) -> some View {
        content
            .searchable(
                text: queryBinding,
                placement: .automatic,
                prompt: "Search pages and blocks"
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
                prompt: "Search pages and blocks"
            )
            .onAppear {
                nativeSearchPresented = true
            }
    }

    @available(iOS 26.0, *)
    private func nativeBottomSearch(_ content: AnyView) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle(searchTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: queryBinding,
                isPresented: nativeSearchPresentedBinding,
                placement: .toolbar,
                prompt: "Search pages and blocks"
            )
            .toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            }
    }

    private func exitSearch() {
        guard !closing else { return }
        closing = true
        emitDismiss()
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
                // Keep local typing ahead of asynchronous core acknowledgements.
                pendingQuery = newValue
                emitQueryChanged(newValue)
            }
        )
    }

    private func emitDismiss() {
        do {
            try context.emit(name: "dismiss", values: [:])
        } catch {
            logger.error("Could not dismiss native search: \(String(describing: error))")
        }
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
private struct LGNavigationContent: View {
    let context: LUIAppleExtensionViewContext
    let rootIndex: Int
    let routeStartIndex: Int
    let depth: Int
    let synchronizationName: String
    let toolbarStartIndex: Int?
    let bottomChromeIndex: Int?
    let bottomOccupiesLayoutSpace: Bool
    let composerDismissalEnabled: Bool
    let rootTransform: ((AnyView) -> AnyView)?
    @State private var path: [Int] = []
    #if os(iOS)
    @State private var transitions = LGNavigationTransitions()
    #endif
    @State private var usesSystemGroupedBackground = false
    @State private var visibleScrollTitle: String?
    @AppStorage("logseq.appearance") private var appearance = "system"
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    var body: some View {
        let _ = context.revision
        navigationLayout
            .onPreferenceChange(LUIListSurfacePreferenceKey.self) { usesSystemBackground in
                usesSystemGroupedBackground = usesSystemBackground
            }
            .onPreferenceChange(LUIScrollTitlePreferenceKey.self) { title in
                if let title { visibleScrollTitle = title }
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
            .background(routeBackground.ignoresSafeArea())
    }

    private var navigationStack: some View {
        NavigationStack(path: pathBinding) {
            rootNavigationSurface
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
                            ToolbarItem(placement: .principal) {
                                rootToolbarTitle
                            }
                            .sharedBackgroundVisibility(.hidden)
                        } else {
                            ToolbarItem(placement: rootLeadingToolbarPlacement) {
                                context.content(for: leadingID)
                            }
                            ToolbarItem(placement: .principal) {
                                rootToolbarTitle
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
            path = desiredPath
        }
        .onChange(of: desiredPath) { _, newPath in
            if path != newPath {
                withAnimation { path = newPath }
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

    private var rootToolbarTitle: some View {
        Text(navigationTitle.isEmpty ? visibleScrollTitle ?? "" : navigationTitle)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("title.main")
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
                let removedCount = max(0, path.count - newPath.count)
                path = newPath
                if removedCount > 0 {
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
